require 'socket'
require 'concurrent'
require 'pathname'
require 'instance_metadata'
require 'instance_agent/agent/base'
require_relative 'deployment_command_tracker'

module InstanceAgent
  module Plugins
    module CodeDeployPlugin
      class CommandPoller < InstanceAgent::Agent::Base

        VERSION = "2013-04-23"

        #Map commands to lifecycle hooks
        DEFAULT_HOOK_MAPPING =
          { "BeforeBlockTraffic"=>["BeforeBlockTraffic"],
            "AfterBlockTraffic"=>["AfterBlockTraffic"],
            "ApplicationStop"=>["ApplicationStop"],
            "BeforeInstall"=>["BeforeInstall"],
            "AfterInstall"=>["AfterInstall"],
            "ApplicationStart"=>["ApplicationStart"],
            "BeforeAllowTraffic"=>["BeforeAllowTraffic"],
            "AfterAllowTraffic"=>["AfterAllowTraffic"],
            "ValidateService"=>["ValidateService"]}

        def initialize
          test_profile = InstanceAgent::Config.config[:codedeploy_test_profile]
          unless ["beta", "gamma"].include?(test_profile.downcase)
            # Remove any user overrides set in the environment.
            # The agent should always pull credentials from the EC2 instance
            # profile or the credentials in the OnPremises config file.
            ENV['AWS_ACCESS_KEY_ID'] = nil
            ENV['AWS_SECRET_ACCESS_KEY'] = nil
            ENV['AWS_CREDENTIAL_FILE'] = nil
          end
          CodeDeployPlugin::OnPremisesConfig.configure
          region = ENV['AWS_REGION'] || InstanceMetadata.region
          @host_identifier = ENV['AWS_HOST_IDENTIFIER'] || InstanceMetadata.host_identifier

          log(:debug, "Configuring deploy control client: Region=#{region.inspect}")
          log(:debug, "Deploy control endpoint override=#{InstanceAgent::Config.config[:deploy_control_endpoint]}")
          log(:debug, "Enable auth policy = #{InstanceAgent::Config.config[:enable_auth_policy]}")

          @deploy_control = InstanceAgent::Plugins::CodeDeployPlugin::CodeDeployControl.new(:region => region, :logger => InstanceAgent::Log, :ssl_ca_directory => ENV['AWS_SSL_CA_DIRECTORY'])
          @deploy_control_client = @deploy_control.get_client

          @plugin = InstanceAgent::Plugins::CodeDeployPlugin::CommandExecutor.new(:hook_mapping => DEFAULT_HOOK_MAPPING)

          @thread_pool = Concurrent::ThreadPoolExecutor.new(
            #TODO: Make these values configurable in agent configuration
            min_threads: 1,
            max_threads: 16,
            max_queue: 0 # unbounded work queue
          )

          log(:debug, "Initializing Host Agent: " +
          "Host Identifier = #{@host_identifier}")
        end

        def validate
          test_profile = InstanceAgent::Config.config[:codedeploy_test_profile]
          unless ["beta", "gamma"].include?(test_profile.downcase)
            log(:debug, "Validating CodeDeploy Plugin Configuration")
            Kernel.abort "Stopping CodeDeploy agent due to SSL validation error." unless @deploy_control.validate_ssl_config
            log(:debug, "CodeDeploy Plugin Configuration is valid")
          end
        end

        # Called during initialization of the child process
        def recover_from_crash?
          begin
            if DeploymentCommandTracker.check_deployment_event_inprogress?() then
              log(:warn, "Deployment tracking file found: #{DeploymentCommandTracker.deployment_dir_path()}. The agent likely restarted while running a customer-supplied script. Failing the lifecycle event.")
              host_command_identifier = DeploymentCommandTracker.most_recent_host_command_identifier()

              log(:info, "Calling PutHostCommandComplete: 'Failed' #{host_command_identifier}")
              @deploy_control_client.put_host_command_complete(
                :command_status => "Failed",
                :diagnostics => {:format => "JSON", :payload => gather_diagnostics_from_failure_after_restart("Failing in-progress lifecycle event after an agent restart.")},
                :host_command_identifier => host_command_identifier)

              DeploymentCommandTracker.clean_ongoing_deployment_dir()
              return true
            end
            # We want to catch-all exceptions so that the child process always can startup succesfully.
          rescue Exception => e
            log(:error, "Exception thrown during restart recovery: #{e}")
            return nil
          end
        end

        def perform
          return unless command = next_command

          #Commands will be executed on a separate thread.
          begin
            @thread_pool.post {
              acknowledge_and_process_command(command)
            }
          rescue Concurrent::RejectedExecutionError
            log(:warn, 'Graceful shutdown initiated, skipping any further polling until agent restarts')
          end
        end

        def graceful_shutdown
          log(:info, "Gracefully shutting down agent child threads now, will wait up to #{ProcessManager::Config.config[:kill_agent_max_wait_time_seconds]} seconds")
          # tell the pool to shutdown in an orderly fashion, allowing in progress work to complete
          @thread_pool.shutdown
          # now wait for all work to complete, wait till the timeout value
          @thread_pool.wait_for_termination ProcessManager::Config.config[:kill_agent_max_wait_time_seconds]
          log(:info, 'All agent child threads have been shut down')
        end

        def acknowledge_and_process_command(command)
          begin
            spec = get_deployment_specification(command)
            return unless acknowledge_command(command, spec)
            process_command(command, spec)
            #Commands that throw an exception will be considered to have failed
          rescue Exception => e
            log(:warn, 'Calling PutHostCommandComplete: "Code Error" ')
            @deploy_control_client.put_host_command_complete(
            :command_status => "Failed",
            :diagnostics => {:format => "JSON", :payload => gather_diagnostics_from_error(e)},
            :host_command_identifier => command.host_command_identifier)
            raise e
          end
        end
        
        def process_command(command, spec)
          log(:debug, "Calling #{@plugin.to_s}.execute_command")
          begin
            deployment_id = InstanceAgent::Plugins::CodeDeployPlugin::DeploymentSpecification.parse(spec).deployment_id
            DeploymentCommandTracker.create_ongoing_deployment_tracking_file(deployment_id, command.host_command_identifier)
            #Successful commands will complete without raising an exception
            @plugin.execute_command(command, spec)
            
            log(:debug, 'Calling PutHostCommandComplete: "Succeeded"')
            @deploy_control_client.put_host_command_complete(
            :command_status => 'Succeeded',
            :diagnostics => {:format => "JSON", :payload => gather_diagnostics()},
            :host_command_identifier => command.host_command_identifier)
            #Commands that throw an exception will be considered to have failed
          rescue ScriptError => e
            log(:debug, 'Calling PutHostCommandComplete: "Code Error" ')
            @deploy_control_client.put_host_command_complete(
            :command_status => "Failed",
            :diagnostics => {:format => "JSON", :payload => gather_diagnostics_from_script_error(e)},
            :host_command_identifier => command.host_command_identifier)
            log(:error, "Error during perform: #{e.class} - #{e.message} - #{e.backtrace.join("\n")}")
            raise e
          rescue Exception => e
            log(:debug, 'Calling PutHostCommandComplete: "Code Error" ')
            @deploy_control_client.put_host_command_complete(
            :command_status => "Failed",
            :diagnostics => {:format => "JSON", :payload => gather_diagnostics_from_error(e)},
            :host_command_identifier => command.host_command_identifier)
            log(:error, "Error during perform: #{e.class} - #{e.message} - #{e.backtrace.join("\n")}")
            raise e
          ensure 
            DeploymentCommandTracker.delete_deployment_command_tracking_file(deployment_id)  
          end
        end
        
        private
        def next_command
          log(:debug, "Calling PollHostCommand:")
          begin
            output = @deploy_control_client.poll_host_command(:host_identifier => @host_identifier)
          rescue Exception => e
            log(:error, "Error polling for host commands: #{e.class} - #{e.message} - #{e.backtrace.join("\n")}")
            raise e
          end
          command = output.host_command
          if command.nil?
            log(:debug, "PollHostCommand: Host Command =  nil")
          else
            log(:debug, "PollHostCommand: "  +
            "Host Identifier = #{command.host_identifier}; "  +
            "Host Command Identifier = #{command.host_command_identifier}; "  +
            "Deployment Execution ID = #{command.deployment_execution_id}; "  +
            "Command Name = #{command.command_name}")
            raise "Host Identifier mismatch: #{@host_identifier} != #{command.host_identifier}" unless @host_identifier.include? command.host_identifier
            raise "Command Name missing" if command.command_name.nil? || command.command_name.empty?
          end
          command
        end

        private
        def get_ack_diagnostics(command, spec)
          is_command_noop = @plugin.is_command_noop?(command.command_name, spec)
          return {:format => "JSON", :payload => {'IsCommandNoop' => is_command_noop}.to_json()}
        end

        private
        def acknowledge_command(command, spec)
          ack_diagnostics = get_ack_diagnostics(command, spec)

          log(:debug, "Calling PutHostCommandAcknowledgement:")
          output =  @deploy_control_client.put_host_command_acknowledgement(
          :diagnostics => ack_diagnostics,
          :host_command_identifier => command.host_command_identifier)
          status = output.command_status
          log(:debug, "Command Status = #{status}")

          if status == "Failed" then
            log(:info, "Received Failed for command #{command.command_name}, checking whether command is a noop...")
            complete_if_noop_command(command)
          end
          true unless status == "Succeeded" || status == "Failed"
        end

        private
        def complete_if_noop_command(command)
          spec = get_deployment_specification(command)

          if @plugin.is_command_noop?(command.command_name, spec) then
            log(:debug, 'Calling PutHostCommandComplete: "Succeeded"')
            @deploy_control_client.put_host_command_complete(
            :command_status => 'Succeeded',
            :diagnostics => {:format => "JSON", :payload => gather_diagnostics("CompletedNoopCommand")},
            :host_command_identifier => command.host_command_identifier)
          end
        end

        private
        def get_deployment_specification(command)
          log(:debug, "Calling GetDeploymentSpecification:")
          output =  @deploy_control_client.get_deployment_specification(
          :deployment_execution_id => command.deployment_execution_id,
          :host_identifier => @host_identifier)
          log(:debug, "GetDeploymentSpecification: " +
          "Deployment System = #{output.deployment_system}")
          raise "Deployment System mismatch: #{@plugin.deployment_system} != #{output.deployment_system}" unless @plugin.deployment_system == output.deployment_system
          raise "Deployment Specification missing" if output.deployment_specification.nil?
          output.deployment_specification.generic_envelope
        end

        private
        def gather_diagnostics_from_script_error(script_error)
          return script_error.to_json
          rescue Exception => e
            return {'error_code' => "Unknown", 'script_name' => script_error.script_name, 'message' => "Attempting minimal diagnostics", 'log' => "Exception #{e.class} occured"}.to_json
        end

        private
        def gather_diagnostics_from_error(error)
          begin
            message = error.message || ""
            raise ScriptError.new(ScriptError::UNKNOWN_ERROR_CODE, "", ScriptLog.new), message
          rescue ScriptError => e
            script_error = e
          end
          gather_diagnostics_from_script_error(script_error)
        end

        private
        def gather_diagnostics_from_failure_after_restart(msg = "")
          begin
            raise ScriptError.new(ScriptError::FAILED_AFTER_RESTART_CODE, "", ScriptLog.new), "Failed: #{msg}"
          rescue ScriptError => e
            script_error = e
          end
          gather_diagnostics_from_script_error(script_error)
        end

        private
        def gather_diagnostics(msg = "")
          begin
            raise ScriptError.new(ScriptError::SUCCEEDED_CODE, "", ScriptLog.new), "Succeeded: #{msg}"
          rescue ScriptError => e
            script_error = e
          end
          gather_diagnostics_from_script_error(script_error)
        end
      end
    end
  end
end
