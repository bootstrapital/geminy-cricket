# frozen_string_literal: true

require "json"

module GeminyCricket
  class McpServer
    DEFAULT_PROTOCOL_VERSION = "2024-11-05"
    SUPPORTED_PROTOCOL_VERSIONS = [
      "2024-11-05",
      "2025-03-26",
      "2025-06-18"
    ].freeze

    ERROR_CODES = {
      parse_error: -32_700,
      invalid_request: -32_600,
      method_not_found: -32_601,
      invalid_params: -32_602,
      internal_error: -32_603
    }.freeze

    def initialize(supervisor: Supervisor.new, io_in: $stdin, io_out: $stdout)
      @supervisor = supervisor
      @io_in = io_in
      @io_out = io_out
      @initialized = false
    end

    def run
      loop do
        message = read_message
        break if message == :eof

        if message == :parse_error
          write_error(nil, ERROR_CODES[:parse_error], "Parse error")
          next
        end

        handle_message(message)
      end
    end

    private

    def handle_message(message)
      unless message.is_a?(Hash)
        return write_error(nil, ERROR_CODES[:invalid_request], "Invalid JSON-RPC message")
      end

      id = message["id"]
      method = message["method"]

      return handle_notification(method, message["params"]) unless message.key?("id")

      case method
      when "initialize"
        handle_initialize(id, message["params"] || {})
      when "ping"
        write_result(id, {})
      when "tools/list"
        assert_initialized!
        write_result(id, { "tools" => tool_definitions })
      when "tools/call"
        assert_initialized!
        handle_tools_call(id, message["params"] || {})
      else
        write_error(id, ERROR_CODES[:method_not_found], "Method not found: #{method}")
      end
    rescue Supervisor::ToolError => e
      write_result(id, tool_error_result(e.to_h))
    rescue StandardError => e
      write_error(id, ERROR_CODES[:internal_error], e.message)
    end

    def handle_notification(method, _params)
      return @initialized = true if method == "notifications/initialized"

      nil
    end

    def handle_initialize(id, params)
      requested_version = params["protocolVersion"]
      negotiated_version = if SUPPORTED_PROTOCOL_VERSIONS.include?(requested_version)
                             requested_version
                           else
                             DEFAULT_PROTOCOL_VERSION
                           end

      @initialized = true

      write_result(
        id,
        {
          "protocolVersion" => negotiated_version,
          "capabilities" => {
            "tools" => {}
          },
          "serverInfo" => {
            "name" => "geminy-cricket",
            "version" => GeminyCricket::VERSION
          }
        }
      )
    end

    def handle_tools_call(id, params)
      tool_name = params.fetch("name")
      schema = tool_schema_for(tool_name)
      raise Supervisor::ToolError.new("Unknown tool: #{tool_name}", code: "tool_not_found") unless schema

      arguments = stringify_keys(params.fetch("arguments", {}))
      validate_input_schema!(schema.fetch("inputSchema"), arguments)

      result = @supervisor.dispatch(tool_name, arguments)

      write_result(
        id,
        {
          "content" => [
            {
              "type" => "text",
              "text" => JSON.pretty_generate(result)
            }
          ],
          "structuredContent" => result,
          "isError" => false
        }
      )
    rescue KeyError => e
      write_result(id, tool_error_result(code: "invalid_arguments", message: "Missing parameter: #{e.message}", retryable: false))
    rescue Supervisor::ToolError => e
      write_result(id, tool_error_result(e.to_h))
    rescue StandardError => e
      write_result(id, tool_error_result(code: "internal_error", message: e.message, retryable: true))
    end

    def validate_input_schema!(schema, args)
      unless args.is_a?(Hash)
        raise Supervisor::ToolError.new("arguments must be an object", code: "invalid_arguments")
      end

      required = Array(schema["required"])
      required.each do |field|
        next if args.key?(field)

        raise Supervisor::ToolError.new("Missing required argument '#{field}'", code: "invalid_arguments")
      end

      if schema["additionalProperties"] == false
        allowed = schema.fetch("properties", {}).keys
        extras = args.keys - allowed
        unless extras.empty?
          raise Supervisor::ToolError.new(
            "Unexpected argument(s): #{extras.join(', ')}",
            code: "invalid_arguments",
            details: { allowed: allowed }
          )
        end
      end

      schema.fetch("properties", {}).each do |name, prop|
        next unless args.key?(name)

        validate_field!(name, args[name], prop)
      end
    end

    def validate_field!(name, value, schema)
      type = schema["type"]

      if type == "string" && !value.is_a?(String)
        raise Supervisor::ToolError.new("'#{name}' must be a string", code: "invalid_arguments")
      end

      if type == "integer" && !value.is_a?(Integer)
        raise Supervisor::ToolError.new("'#{name}' must be an integer", code: "invalid_arguments")
      end

      if type == "object" && !value.is_a?(Hash)
        raise Supervisor::ToolError.new("'#{name}' must be an object", code: "invalid_arguments")
      end

      if schema["enum"] && !schema["enum"].include?(value)
        raise Supervisor::ToolError.new(
          "'#{name}' must be one of #{schema['enum'].join(', ')}",
          code: "invalid_arguments"
        )
      end

      if value.is_a?(Integer)
        min = schema["minimum"]
        max = schema["maximum"]
        if min && value < min
          raise Supervisor::ToolError.new("'#{name}' must be >= #{min}", code: "invalid_arguments")
        end
        if max && value > max
          raise Supervisor::ToolError.new("'#{name}' must be <= #{max}", code: "invalid_arguments")
        end
      end
    end

    def assert_initialized!
      return if @initialized

      raise Supervisor::ToolError.new(
        "Client must call initialize before tool methods",
        code: "not_initialized",
        retryable: true
      )
    end

    def tool_definitions
      [
        {
          "name" => "gc_start",
          "description" => "Create a new Geminy Cricket session for a top-level goal.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "goal" => { "type" => "string", "description" => "Feature or task goal." }
            },
            "required" => ["goal"],
            "additionalProperties" => false
          },
          "annotations" => {
            "examples" => [
              { "goal" => "Ship auth flow with reset password" }
            ]
          }
        },
        {
          "name" => "gc_plan_step",
          "description" => "Record a durable plan step for the session.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "desc" => { "type" => "string", "description" => "Description of the next step." },
              "session_id" => { "type" => "string", "description" => "Optional explicit session." }
            },
            "required" => ["desc"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_verify",
          "description" => "Run tests (RSpec or Minitest) and return a normalized chirp when failing.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "scope" => { "type" => "string", "description" => "Test scope path, directory, or pattern." },
              "framework" => {
                "type" => "string",
                "enum" => %w[auto rspec minitest],
                "description" => "Framework selection. Default: auto."
              },
              "session_id" => { "type" => "string", "description" => "Optional explicit session." },
              "run_id" => { "type" => "string", "description" => "Optional run for checkpoint cadence." }
            },
            "required" => ["scope"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_recall",
          "description" => "Find related journal entries with lexical, semantic, or hybrid ranking.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "query" => { "type" => "string", "description" => "Search phrase." },
              "mode" => {
                "type" => "string",
                "enum" => %w[hybrid lexical semantic],
                "description" => "Retrieval mode. Defaults to hybrid."
              },
              "limit" => {
                "type" => "integer",
                "minimum" => 1,
                "maximum" => 100,
                "description" => "Max matches. Defaults to 10."
              },
              "session_id" => { "type" => "string", "description" => "Optional explicit session." }
            },
            "required" => ["query"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_record_logic",
          "description" => "Persist reasoning notes to journal.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "summary" => { "type" => "string", "description" => "Reasoning summary." },
              "session_id" => { "type" => "string", "description" => "Optional explicit session." },
              "run_id" => { "type" => "string", "description" => "Optional run for traceability." }
            },
            "required" => ["summary"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_reindex_embeddings",
          "description" => "Backfill/reindex embeddings for existing plan items and journal entries.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "session_id" => { "type" => "string", "description" => "Optional session filter." },
              "entity_type" => {
                "type" => "string",
                "enum" => %w[plan_item journal_entry],
                "description" => "Optional entity scope for indexing."
              }
            },
            "required" => [],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_begin_run",
          "description" => "Start a durable run lifecycle for an agent.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "agent_id" => { "type" => "string", "description" => "Agent identifier (e.g. codex-main)." },
              "session_id" => { "type" => "string", "description" => "Optional explicit session." }
            },
            "required" => ["agent_id"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_checkpoint",
          "description" => "Write a checkpoint summary for a run.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "run_id" => { "type" => "string" },
              "summary" => { "type" => "string" },
              "metadata" => { "type" => "object" }
            },
            "required" => ["run_id", "summary"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_heartbeat",
          "description" => "Update run heartbeat and status.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "run_id" => { "type" => "string" },
              "status" => {
                "type" => "string",
                "enum" => Store::RUN_STATUSES
              },
              "metadata" => { "type" => "object" }
            },
            "required" => ["run_id", "status"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_pause",
          "description" => "Pause a run with a human-readable reason.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "run_id" => { "type" => "string" },
              "reason" => { "type" => "string" }
            },
            "required" => ["run_id", "reason"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_resume",
          "description" => "Resume a paused/blocked run and return rehydration packet.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "run_id" => { "type" => "string" }
            },
            "required" => ["run_id"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_end_run",
          "description" => "Finalize a run with completed or failed outcome.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "run_id" => { "type" => "string" },
              "outcome" => { "type" => "string", "enum" => %w[completed failed] },
              "summary" => { "type" => "string" }
            },
            "required" => ["run_id", "outcome", "summary"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_next_step",
          "description" => "Return highest-priority incomplete plan item with context packet.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "session_id" => { "type" => "string" },
              "run_id" => { "type" => "string" }
            },
            "required" => [],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_context_packet",
          "description" => "Build normalized rehydration packet for restart/handoff.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "run_id" => { "type" => "string" },
              "budget_tokens" => { "type" => "integer", "minimum" => 256, "maximum" => 32768 }
            },
            "required" => ["run_id"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_compact",
          "description" => "Create a compressed checkpoint and return prompt-safe context packet.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "run_id" => { "type" => "string" },
              "reason" => { "type" => "string" },
              "budget_tokens" => { "type" => "integer", "minimum" => 256, "maximum" => 32768 }
            },
            "required" => ["run_id", "reason"],
            "additionalProperties" => false
          }
        },
        {
          "name" => "gc_health",
          "description" => "Return service health and backend status for operators.",
          "inputSchema" => {
            "type" => "object",
            "properties" => {},
            "required" => [],
            "additionalProperties" => false
          }
        }
      ]
    end

    def tool_schema_for(name)
      tool_definitions.find { |tool| tool["name"] == name }
    end

    def stringify_keys(hash)
      hash.each_with_object({}) do |(key, value), memo|
        memo[key.to_s] = value
      end
    end

    def read_message
      line = @io_in.gets
      return :eof if line.nil?

      text = line.strip
      return read_message if text.empty? # Skip empty lines

      if text.downcase.start_with?("content-length:")
        # It's using headers
        content_length = text[/\d+/].to_i
        # Read the remaining header lines until the empty line
        loop do
          header_line = @io_in.gets
          break if header_line.nil? || header_line.strip.empty?
        end
        body = @io_in.read(content_length)
        return :parse_error if body.nil? || body.empty?

        JSON.parse(body)
      else
        # It's raw JSON
        JSON.parse(text)
      end
    rescue JSON::ParserError => e
      log_swallowed_error(event: "mcp_parse_error", exception: e)
      :parse_error
    end

    def write_result(id, result)
      write_message(
        {
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => result
        }
      )
    end

    def write_error(id, code, message)
      write_message(
        {
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => {
            "code" => code,
            "message" => message
          }
        }
      )
    end

    def tool_error_result(error_hash)
      code = error_hash[:code] || error_hash["code"]
      message = error_hash[:message] || error_hash["message"]
      retryable = error_hash[:retryable] || error_hash["retryable"]
      details = error_hash[:details] || error_hash["details"] || {}

      {
        "content" => [
          {
            "type" => "text",
            "text" => "#{code}: #{message}"
          }
        ],
        "structuredContent" => {
          "error" => {
            "code" => code,
            "message" => message,
            "retryable" => retryable,
            "details" => details
          }
        },
        "isError" => true
      }
    end

    def write_message(message)
      payload = JSON.generate(message)
      # warn(JSON.generate({ event: "mcp_writing_response", payload: payload }))
      @io_out.puts(payload)
      @io_out.flush
    end

    def log_swallowed_error(event:, exception:)
      warn(
        JSON.generate(
          event: event,
          error_class: exception.class.name,
          message: exception.message
        )
      )
    end
  end
end
