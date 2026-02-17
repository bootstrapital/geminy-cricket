# frozen_string_literal: true

module GeminyCricket
  module Config
    module_function

    def root
      @root ||= File.expand_path("../..", __dir__)
    end

    def project_root
      @project_root ||= begin
        curr = Dir.pwd
        while curr != "/"
          return curr if Dir.exist?(File.join(curr, ".git")) || Dir.exist?(File.join(curr, ".geminy-cricket"))
          curr = File.dirname(curr)
        end
        Dir.pwd
      end
    end

    def db_path
      ENV.fetch("GC_DB_PATH", File.join(project_root, ".geminy-cricket", "supervisor.duckdb"))
    end

    def dashboard_port
      Integer(ENV.fetch("GC_DASHBOARD_PORT", "48203"))
    end

    def bind_host
      ENV.fetch("GC_BIND_HOST", "127.0.0.1")
    end

    def snippet_radius
      Integer(ENV.fetch("GC_SNIPPET_RADIUS", "3"))
    end

    def embedding_model
      ENV.fetch("GC_EMBEDDING_MODEL", "sentence-transformers/all-MiniLM-L6-v2")
    end

    def embedding_dimensions
      Integer(ENV.fetch("GC_EMBEDDING_DIMS", "384"))
    end

    def context_token_budget
      Integer(ENV.fetch("GC_CONTEXT_TOKEN_BUDGET", "6000"))
    end

    def compaction_loop_interval
      Integer(ENV.fetch("GC_COMPACTION_LOOP_INTERVAL", "20"))
    end

    def compaction_max_history_entries
      Integer(ENV.fetch("GC_COMPACTION_MAX_HISTORY_ENTRIES", "12"))
    end

    def server_url
      ENV.fetch("GC_SERVER_URL", "http://127.0.0.1:#{dashboard_port}")
    end

    def supervisor_mode
      ENV.fetch("GC_SUPERVISOR_MODE", "server")
    end

    def server_timeout_seconds
      Integer(ENV.fetch("GC_SERVER_TIMEOUT_SECONDS", "15"))
    end

    def tool_api_key
      ENV["GC_TOOL_API_KEY"].to_s.strip
    end

    def tool_api_auth_required?
      !tool_api_key.empty?
    end

    def strict_bind_auth?
      truthy?(ENV.fetch("GC_STRICT_BIND_AUTH", "false"))
    end

    def db_mutex_enabled?
      !truthy?(ENV.fetch("GC_DB_MUTEX_DISABLED", "false"))
    end

    def puma_min_threads
      Integer(ENV.fetch("PUMA_MIN_THREADS", "0"))
    end

    def puma_max_threads
      Integer(ENV.fetch("PUMA_MAX_THREADS", "1"))
    end

    def truthy?(value)
      %w[1 true yes on].include?(value.to_s.downcase)
    end
  end
end
