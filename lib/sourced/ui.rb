# frozen_string_literal: true

require_relative "ui/version"

module Sourced
  module UI
    class Error < StandardError; end

    # A helper to handle commands in web controllers
    # and stream errors back to the UI.
    # UI forms are assumed to use the Sourced::UI::Components::Command component
    # which includes the expected input names and _cid value.
    # @example
    #   Sourced::UI.streaming_command_errors(cmd, datastar) do |cmd|
    #     Sourced.schedule_commands([cmd])
    #   end
    #
    # @param cmd [Sourced::Command] the command to process
    # @param datastar [Datastar::Dispatcher] the datastar instance to stream errors to
    def self.streaming_command_errors(cmd, datastar, &)
      if cmd.valid? # <== schedule valid command for processing
        yield cmd if block_given?
      elsif cmd.errors[:payload] # <== Send back error fragments to UI
        cid = datastar.signals['command']['_cid']

        #[cid]-[name]-errors
        errors = cmd.errors[:payload]
        datastar.send(:stream_no_heartbeat) do |sse|
          errors.each do |field, error|
            # 'text', "can't be blank"
            field_id = [cid, field].join('-')
            sse.merge_fragments Sourced::UI::Components::Command::ErrorMessages.new(field_id, error)
            wrapper_id = [field_id, 'wrapper'].join('-')
            sse.execute_script %(document.getElementById("#{wrapper_id}").classList.add('errors'))
          end
        end
      else # <== This should never happen
        raise Sourced::UI::Error, "Command #{cmd.type} is invalid: #{cmd.errors}"
      end
    end
  end
end
