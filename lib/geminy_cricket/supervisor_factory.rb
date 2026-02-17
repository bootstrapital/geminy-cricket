# frozen_string_literal: true

module GeminyCricket
  module SupervisorFactory
    module_function

    def build
      mode = Config.supervisor_mode

      case mode
      when "server"
        Client.new
      when "direct"
        Supervisor.new
      when "auto"
        client = Client.new
        client.healthy? ? client : Supervisor.new
      else
        raise ArgumentError, "Invalid GC_SUPERVISOR_MODE '#{mode}'. Use server|direct|auto"
      end
    end
  end
end
