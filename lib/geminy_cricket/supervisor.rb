# frozen_string_literal: true

require "json"
require "socket"
require "uri"
require "securerandom"

module GeminyCricket
  class Supervisor
    class ToolError < StandardError
      attr_reader :code, :retryable, :details

      def initialize(message, code: "invalid_request", retryable: false, details: {})
        super(message)
        @code = code
        @retryable = retryable
        @details = details
      end

      def to_h
        {
          code: code,
          message: message,
          retryable: retryable,
          details: details
        }
      end
    end

    def initialize(store: Store.new)
      @store = store
      @active_session_id = nil
    end

    def dispatch(tool, args = {})
      normalized = stringify_keys(args || {})
      tool_name = tool.to_s

      case tool_name
      when "gc_start" then gc_start(normalized.fetch("goal"))
      when "gc_plan_step" then gc_plan_step(normalized.fetch("desc"), session_id: normalized["session_id"])
      when "gc_verify"
        gc_verify(
          normalized.fetch("scope"),
          framework: normalized["framework"] || "auto",
          session_id: normalized["session_id"],
          run_id: normalized["run_id"]
        )
      when "gc_recall"
        gc_recall(
          normalized.fetch("query"),
          mode: normalized["mode"],
          limit: normalized["limit"],
          session_id: normalized["session_id"]
        )
      when "gc_record_logic"
        gc_record_logic(
          normalized.fetch("summary"),
          session_id: normalized["session_id"],
          run_id: normalized["run_id"]
        )
      when "gc_reindex_embeddings"
        gc_reindex_embeddings(session_id: normalized["session_id"], entity_type: normalized["entity_type"])
      when "gc_begin_run"
        gc_begin_run(normalized.fetch("agent_id"), session_id: normalized["session_id"])
      when "gc_checkpoint"
        gc_checkpoint(normalized.fetch("run_id"), normalized.fetch("summary"), metadata: normalized["metadata"] || {})
      when "gc_heartbeat"
        gc_heartbeat(normalized.fetch("run_id"), normalized.fetch("status"), metadata: normalized["metadata"] || {})
      when "gc_pause"
        gc_pause(normalized.fetch("run_id"), normalized.fetch("reason"))
      when "gc_resume"
        gc_resume(normalized.fetch("run_id"))
      when "gc_end_run"
        gc_end_run(normalized.fetch("run_id"), normalized.fetch("outcome"), normalized.fetch("summary"))
      when "gc_next_step"
        gc_next_step(session_id: normalized["session_id"], run_id: normalized["run_id"])
      when "gc_context_packet"
        gc_context_packet(normalized.fetch("run_id"), budget_tokens: normalized["budget_tokens"])
      when "gc_compact"
        gc_compact(normalized.fetch("run_id"), normalized.fetch("reason"), budget_tokens: normalized["budget_tokens"])
      when "gc_health"
        gc_health
      else
        raise ToolError.new("Unknown tool: #{tool_name}", code: "tool_not_found")
      end
    rescue KeyError => e
      raise ToolError.new("Missing required argument: #{e.message}", code: "invalid_arguments")
    rescue ArgumentError => e
      raise ToolError.new(e.message, code: "invalid_arguments")
    end

    def gc_start(goal)
      session = @store.create_session(goal: goal)
      @active_session_id = session_value(session, "id")

      {
        tool: "gc_start",
        session_id: @active_session_id,
        goal: goal,
        dashboard_url: dashboard_url,
        message: "Session created. Start dashboard with: bundle exec ruby bin/geminy-cricket-server"
      }
    end

    def gc_plan_step(description, session_id: nil)
      resolved = resolve_session(session_id: session_id)
      item = @store.create_plan_item(session_id: resolved[:session_id], description: description)

      {
        tool: "gc_plan_step",
        session_id: resolved[:session_id],
        session_resolution: resolved[:resolution],
        plan_item: item
      }
    end

    def gc_verify(scope, framework: "auto", session_id: nil, run_id: nil)
      validate_verify_scope!(scope)
      resolved = resolve_session(session_id: session_id, run_id: run_id)
      verifier = TestVerifier.new(scope: scope, framework: framework)
      verification = verifier.verify

      entry_type = case verification[:status]
                   when "passed" then "test_success"
                   when "failed" then "test_failure"
                   else "reasoning"
                   end

      @store.create_journal_entry(
        session_id: resolved[:session_id],
        entry_type: entry_type,
        content: JSON.generate(verification),
        metadata: { scope: scope, framework: verification[:framework_used] }
      )

      if verification[:status] == "failed"
        related = @store.recall_journal(verification.dig(:chirp, :exception).to_s, limit: 3, session_id: resolved[:session_id])
        verification[:chirp][:related_failures] = related
      end

      if run_id
        @store.create_checkpoint(
          run_id: run_id,
          summary: "verify #{verification[:status]} (#{verification[:framework_used]}) for #{scope}",
          metadata: {
            type: "verify",
            scope: scope,
            framework: verification[:framework_used],
            status: verification[:status]
          }
        )
      end

      {
        tool: "gc_verify",
        session_id: resolved[:session_id],
        session_resolution: resolved[:resolution],
        run_id: run_id,
        result: verification
      }
    end

    def gc_recall(query, mode: nil, limit: nil, session_id: nil)
      resolved = resolve_session(session_id: session_id)
      recall_mode = mode || "hybrid"
      recall_limit = Integer(limit || 10)

      {
        tool: "gc_recall",
        session_id: resolved[:session_id],
        session_resolution: resolved[:resolution],
        query: query,
        mode: recall_mode,
        limit: recall_limit,
        backend: @store.recall_backend_status,
        matches: @store.recall_journal(query, mode: recall_mode, limit: recall_limit, session_id: resolved[:session_id])
      }
    end

    def gc_record_logic(summary, session_id: nil, run_id: nil)
      resolved = resolve_session(session_id: session_id, run_id: run_id)
      entry = @store.create_journal_entry(
        session_id: resolved[:session_id],
        entry_type: "reasoning",
        content: summary,
        metadata: {}
      )

      {
        tool: "gc_record_logic",
        session_id: resolved[:session_id],
        session_resolution: resolved[:resolution],
        run_id: run_id,
        entry: entry
      }
    end

    def gc_reindex_embeddings(session_id: nil, entity_type: nil)
      if entity_type && !%w[plan_item journal_entry].include?(entity_type)
        raise ToolError.new("entity_type must be plan_item or journal_entry", code: "invalid_arguments")
      end

      counts = @store.reindex_embeddings(session_id: session_id, entity_type: entity_type)

      {
        tool: "gc_reindex_embeddings",
        session_id: session_id,
        entity_type: entity_type || "all",
        backend: @store.recall_backend_status,
        counts: counts
      }
    end

    def gc_begin_run(agent_id, session_id: nil)
      resolved = resolve_session(session_id: session_id)
      run = @store.create_agent_run(
        session_id: resolved[:session_id],
        agent_id: agent_id,
        status: "running",
        resume_token: SecureRandom.hex(16)
      )

      {
        tool: "gc_begin_run",
        session_id: resolved[:session_id],
        session_resolution: resolved[:resolution],
        run: run,
        context_packet: build_context_packet(run, budget_tokens: Config.context_token_budget)
      }
    end

    def gc_checkpoint(run_id, summary, metadata: {})
      run = require_run(run_id)
      checkpoint = @store.create_checkpoint(run_id: run_id, summary: summary, metadata: metadata)

      {
        tool: "gc_checkpoint",
        run_id: run_id,
        session_id: session_value(run, "session_id"),
        checkpoint: checkpoint
      }
    end

    def gc_heartbeat(run_id, status, metadata: {})
      run = @store.heartbeat_run(run_id: run_id, status: status, metadata: metadata)

      packet = build_context_packet(run, budget_tokens: Config.context_token_budget)
      trigger = packet[:context_management][:compaction_recommended]
      if trigger
        @store.create_checkpoint(
          run_id: run_id,
          summary: "Automatic checkpoint due to compaction trigger: #{trigger}",
          metadata: { type: "auto_compaction_trigger", trigger: trigger }
        )
      end

      {
        tool: "gc_heartbeat",
        run_id: run_id,
        run: run,
        context_management: packet[:context_management]
      }
    end

    def gc_pause(run_id, reason)
      run = require_run(run_id)
      updated = @store.update_run_status(run_id: run_id, status: "paused", summary: reason)
      @store.create_journal_entry(
        session_id: session_value(run, "session_id"),
        entry_type: "blocker",
        content: reason,
        metadata: { run_id: run_id, type: "pause" }
      )

      {
        tool: "gc_pause",
        run_id: run_id,
        run: updated
      }
    end

    def gc_resume(run_id)
      run = require_run(run_id)
      updated = @store.update_run_status(run_id: run_id, status: "running", summary: "resumed")

      {
        tool: "gc_resume",
        run_id: run_id,
        session_id: session_value(run, "session_id"),
        run: updated,
        context_packet: build_context_packet(updated, budget_tokens: Config.context_token_budget, forced_reason: "handoff_or_restart")
      }
    end

    def gc_end_run(run_id, outcome, summary)
      status = case outcome.to_s
               when "completed" then "completed"
               when "failed" then "failed"
               else
                 raise ToolError.new("outcome must be completed or failed", code: "invalid_arguments")
               end

      updated = @store.update_run_status(run_id: run_id, status: status, summary: summary, ended: true)
      @store.create_checkpoint(run_id: run_id, summary: "Run ended: #{summary}", metadata: { type: "end_run", outcome: outcome })

      {
        tool: "gc_end_run",
        run_id: run_id,
        run: updated
      }
    end

    def gc_next_step(session_id: nil, run_id: nil)
      resolved = resolve_session(session_id: session_id, run_id: run_id, require_explicit: true)
      plan_item = @store.next_incomplete_plan_item(resolved[:session_id])
      run = run_id ? require_run(run_id) : @store.latest_run_for_session(resolved[:session_id])

      {
        tool: "gc_next_step",
        session_id: resolved[:session_id],
        run_id: run && session_value(run, "id"),
        session_resolution: resolved[:resolution],
        next_plan_item: plan_item,
        context_packet: run ? build_context_packet(run, budget_tokens: Config.context_token_budget) : nil
      }
    end

    def gc_context_packet(run_id, budget_tokens: nil)
      run = require_run(run_id)
      {
        tool: "gc_context_packet",
        run_id: run_id,
        context_packet: build_context_packet(run, budget_tokens: budget_tokens || Config.context_token_budget)
      }
    end

    def gc_compact(run_id, reason, budget_tokens: nil)
      run = require_run(run_id)
      packet = build_context_packet(run, budget_tokens: budget_tokens || Config.context_token_budget)

      compact_summary = [
        "Compaction reason: #{reason}",
        "Goal: #{packet[:goal_summary]}",
        "Active step: #{packet.dig(:active_plan_items, 0, 'description') || 'none'}",
        "Latest checkpoint: #{packet.dig(:latest_checkpoint, 'summary') || 'none'}",
        "Latest failure: #{packet.dig(:latest_failing_chirp, 'summary') || 'none'}",
        "Next action: #{packet[:next_intended_action] || 'none'}"
      ].join("\n")

      checkpoint = @store.create_checkpoint(
        run_id: run_id,
        summary: compact_summary,
        metadata: {
          type: "manual_compaction",
          reason: reason,
          budget_tokens: budget_tokens || Config.context_token_budget,
          estimated_tokens: packet.dig(:context_management, :estimated_prompt_tokens)
        }
      )

      {
        tool: "gc_compact",
        run_id: run_id,
        checkpoint: checkpoint,
        context_packet: packet
      }
    end

    def gc_health
      session = @store.latest_active_session
      run = session ? @store.latest_run_for_session(session_value(session, "id")) : nil

      {
        tool: "gc_health",
        db_path: Config.db_path,
        active_session: session,
        latest_run: run,
        recall_backend: @store.recall_backend_status,
        context: {
          token_budget: Config.context_token_budget,
          compaction_loop_interval: Config.compaction_loop_interval
        }
      }
    end

    private

    def dashboard_url
      "http://127.0.0.1:#{Config.dashboard_port}"
    end

    def resolve_session(session_id: nil, run_id: nil, require_explicit: false)
      if run_id
        run = require_run(run_id)
        sid = session_value(run, "session_id")
        @active_session_id = sid
        return {
          session_id: sid,
          resolution: {
            mode: "from_run_id",
            used_legacy_fallback: false
          }
        }
      end

      if session_id
        session = @store.find_session(session_id)
        raise ToolError.new("Unknown session_id: #{session_id}", code: "not_found") unless session

        @active_session_id = session_id
        return {
          session_id: session_id,
          resolution: {
            mode: "explicit_session_id",
            used_legacy_fallback: false
          }
        }
      end

      if require_explicit
        raise ToolError.new("session_id or run_id is required", code: "invalid_arguments")
      end

      @active_session_id ||= @store.latest_active_session&.dig("id") || @store.latest_active_session&.dig(:id)
      unless @active_session_id
        raise ToolError.new("No active session. Run gc_start first.", code: "not_found")
      end

      {
        session_id: @active_session_id,
        resolution: {
          mode: "legacy_latest_active_session",
          used_legacy_fallback: true
        }
      }
    end

    def require_run(run_id)
      run = @store.find_run(run_id)
      raise ToolError.new("Unknown run_id: #{run_id}", code: "not_found") unless run

      run
    end

    def build_context_packet(run, budget_tokens:, forced_reason: nil)
      run_id = session_value(run, "id")
      session_id = session_value(run, "session_id")
      session = @store.find_session(session_id)
      latest_checkpoint = @store.latest_checkpoint(run_id)
      plan_item = @store.next_incomplete_plan_item(session_id)
      failing = latest_failing_chirp(session_id)
      blockers = @store.unresolved_blockers(session_id, limit: 5)

      hot_entries = @store.list_journal_entries(session_id, limit: Config.compaction_max_history_entries)
      hot_payload = fit_entries_to_budget(hot_entries, budget_tokens: budget_tokens)

      loop_count = session_value(run, "loop_count").to_i
      compaction_reason = forced_reason || detect_compaction_trigger(
        estimated_prompt_tokens: hot_payload[:estimated_tokens],
        budget_tokens: budget_tokens,
        loop_count: loop_count
      )

      {
        session_id: session_id,
        run_id: run_id,
        goal_summary: session_value(session, "goal"),
        active_plan_items: plan_item ? [plan_item] : [],
        latest_checkpoint: latest_checkpoint,
        latest_failing_chirp: failing,
        unresolved_blockers: blockers,
        next_intended_action: plan_item ? session_value(plan_item, "description") : "Await new plan step",
        hot_context: hot_payload[:entries],
        context_management: {
          estimated_prompt_tokens: hot_payload[:estimated_tokens],
          budget_tokens: budget_tokens,
          compaction_recommended: compaction_reason,
          triggers: {
            token_budget_exceeded: hot_payload[:estimated_tokens] > budget_tokens,
            periodic_loop_compaction: loop_count.positive? && (loop_count % Config.compaction_loop_interval).zero?,
            handoff_or_restart: forced_reason == "handoff_or_restart"
          }
        }
      }
    end

    def latest_failing_chirp(session_id)
      entry = @store.latest_journal_entry(session_id, entry_type: "test_failure")
      return nil unless entry

      parsed = parse_json(session_value(entry, "content"))
      chirp = parsed["chirp"] || parsed[:chirp]
      return nil unless chirp

      {
        summary: parsed["summary"] || parsed[:summary],
        file: chirp["file"] || chirp[:file],
        line: chirp["line"] || chirp[:line],
        exception: chirp["exception"] || chirp[:exception],
        snippet: chirp["snippet"] || chirp[:snippet]
      }
    end

    def detect_compaction_trigger(estimated_prompt_tokens:, budget_tokens:, loop_count:)
      return "token_budget_exceeded" if estimated_prompt_tokens > budget_tokens
      return "periodic_loop_compaction" if loop_count.positive? && (loop_count % Config.compaction_loop_interval).zero?

      nil
    end

    def validate_verify_scope!(scope)
      raw = scope.to_s.strip
      if raw.empty?
        raise ToolError.new("scope cannot be empty", code: "unsafe_scope")
      end

      if raw.start_with?("-") || raw.include?("\n") || raw.include?("\0")
        raise ToolError.new("scope contains unsafe characters", code: "unsafe_scope")
      end

      if raw.include?("..")
        raise ToolError.new("scope cannot include parent traversal", code: "unsafe_scope")
      end

      allowed_prefixes = ["spec", "test"]
      prefix_ok = allowed_prefixes.any? { |prefix| raw == prefix || raw.start_with?("#{prefix}/") }
      unless prefix_ok
        raise ToolError.new("scope must be under spec/ or test/", code: "unsafe_scope")
      end

      expanded = File.expand_path(raw, Config.root)
      root = Config.root
      unless expanded.start_with?("#{root}/spec") || expanded.start_with?("#{root}/test")
        raise ToolError.new("scope resolved outside allowed test roots", code: "unsafe_scope")
      end
    end

    def fit_entries_to_budget(entries, budget_tokens:)
      max_chars = budget_tokens.to_i * 4
      used_chars = 0
      kept = []

      entries.each do |entry|
        serialized = JSON.generate(entry)
        break if used_chars + serialized.length > max_chars

        kept << entry
        used_chars += serialized.length
      end

      {
        entries: kept,
        estimated_tokens: (used_chars / 4.0).ceil
      }
    end

    def stringify_keys(hash)
      hash.each_with_object({}) do |(k, v), memo|
        memo[k.to_s] = v
      end
    end

    def parse_json(value)
      return {} if value.nil? || value == ""
      return value if value.is_a?(Hash)

      JSON.parse(value)
    rescue JSON::ParserError
      {}
    end

    def session_value(record, key)
      return nil unless record

      record[key] || record[key.to_sym]
    end
  end
end
