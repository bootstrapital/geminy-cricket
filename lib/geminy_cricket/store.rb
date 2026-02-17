# frozen_string_literal: true

require "duckdb"
require "fileutils"
require "json"
require "securerandom"
require "time"

module GeminyCricket
  class Store
    RUN_STATUSES = %w[
      queued
      running
      waiting_for_human
      paused
      blocked
      completed
      failed
    ].freeze

    def initialize(path: Config.db_path, embedder: Embedder.new)
      @path = path
      @embedder = embedder
      @vss_enabled = false
      @vss_error = nil
      @db_mutex = Mutex.new

      FileUtils.mkdir_p(File.dirname(path))
      @connection = open_connection(path)
      bootstrap!
    end

    def create_session(goal:)
      id = SecureRandom.uuid
      execute(
        "INSERT INTO sessions (id, goal, status) VALUES (?, ?, ?)",
        [id, goal, "active"]
      )
      find_session(id)
    end

    def find_session(id)
      rows("SELECT * FROM sessions WHERE id = ?", [id]).first
    end

    def latest_active_session
      rows("SELECT * FROM sessions WHERE status = 'active' ORDER BY created_at DESC LIMIT 1").first
    end

    def create_plan_item(session_id:, description:, embedding: nil)
      id = SecureRandom.uuid
      execute(
        "INSERT INTO plan_items (id, session_id, description, embedding, is_completed) VALUES (?, ?, ?, ?, ?)",
        [id, session_id, description, embedding, false]
      )

      index_entity(entity_type: "plan_item", entity_id: id, content: description)
      rows("SELECT * FROM plan_items WHERE id = ?", [id]).first
    end

    def list_plan_items(session_id)
      rows("SELECT * FROM plan_items WHERE session_id = ? ORDER BY is_completed, rowid", [session_id])
    end

    def next_incomplete_plan_item(session_id)
      rows(
        "SELECT * FROM plan_items WHERE session_id = ? AND is_completed = FALSE ORDER BY rowid LIMIT 1",
        [session_id]
      ).first
    end

    def complete_plan_item(plan_item_id, completed: true)
      execute("UPDATE plan_items SET is_completed = ? WHERE id = ?", [completed, plan_item_id])
      rows("SELECT * FROM plan_items WHERE id = ?", [plan_item_id]).first
    end

    def create_journal_entry(session_id:, entry_type:, content:, metadata: {})
      id = SecureRandom.uuid
      execute(
        "INSERT INTO journal_entries (id, session_id, entry_type, content, metadata) VALUES (?, ?, ?, ?, ?)",
        [id, session_id, entry_type, content, JSON.generate(metadata)]
      )

      index_entity(entity_type: "journal_entry", entity_id: id, content: content)
      rows("SELECT * FROM journal_entries WHERE id = ?", [id]).first
    end

    def recall_journal(query, limit: 10, mode: "hybrid", session_id: nil)
      normalized_mode = normalize_recall_mode(mode)

      case normalized_mode
      when "lexical"
        lexical_journal_matches(query, limit: limit, session_id: session_id)
      when "semantic"
        semantic_journal_matches(query, limit: limit, session_id: session_id)
      else
        hybrid_journal_matches(query, limit: limit, session_id: session_id)
      end
    end

    def recall_backend_status
      {
        embedder_available: @embedder.available?,
        embedder_model: @embedder.model,
        embedding_dimensions: Config.embedding_dimensions,
        vss_enabled: @vss_enabled,
        vss_error: @vss_error,
        embedder_error: @embedder.error_message
      }
    end

    def list_journal_entries(session_id, limit: 100)
      rows(
        "SELECT * FROM journal_entries WHERE session_id = ? ORDER BY timestamp DESC LIMIT ?",
        [session_id, limit]
      )
    end

    def latest_journal_entry(session_id, entry_type: nil)
      if entry_type
        rows(
          "SELECT * FROM journal_entries WHERE session_id = ? AND entry_type = ? ORDER BY timestamp DESC LIMIT 1",
          [session_id, entry_type]
        ).first
      else
        rows(
          "SELECT * FROM journal_entries WHERE session_id = ? ORDER BY timestamp DESC LIMIT 1",
          [session_id]
        ).first
      end
    end

    def unresolved_blockers(session_id, limit: 5)
      rows(
        "SELECT * FROM journal_entries WHERE session_id = ? AND entry_type = 'blocker' ORDER BY timestamp DESC LIMIT ?",
        [session_id, limit]
      )
    end

    def create_agent_run(session_id:, agent_id:, status: "running", resume_token: nil)
      normalized_status = normalize_run_status(status)
      id = SecureRandom.uuid
      execute(
        <<~SQL,
          INSERT INTO agent_runs (
            id, session_id, agent_id, status, started_at, last_heartbeat_at, resume_token, loop_count, metadata
          ) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, 0, ?)
        SQL
        [id, session_id, agent_id, normalized_status, resume_token, "{}"]
      )
      find_run(id)
    end

    def find_run(run_id)
      rows("SELECT * FROM agent_runs WHERE id = ?", [run_id]).first
    end

    def latest_run_for_session(session_id)
      rows("SELECT * FROM agent_runs WHERE session_id = ? ORDER BY started_at DESC LIMIT 1", [session_id]).first
    end

    def update_run_status(run_id:, status:, summary: nil, ended: false)
      normalized_status = normalize_run_status(status)
      sql = "UPDATE agent_runs SET status = ?, last_heartbeat_at = CURRENT_TIMESTAMP"
      params = [normalized_status]

      if summary
        sql += ", last_status_summary = ?"
        params << summary
      end

      if ended
        sql += ", ended_at = CURRENT_TIMESTAMP"
      end

      sql += " WHERE id = ?"
      params << run_id

      execute(sql, params)
      find_run(run_id)
    end

    def heartbeat_run(run_id:, status:, metadata: {})
      run = find_run(run_id)
      raise ArgumentError, "Unknown run_id: #{run_id}" unless run

      normalized_status = normalize_run_status(status)
      current_loop_count = run_value(run, "loop_count").to_i
      merged_metadata = merge_run_metadata(run, metadata)

      execute(
        <<~SQL,
          UPDATE agent_runs
          SET status = ?,
              last_heartbeat_at = CURRENT_TIMESTAMP,
              loop_count = ?,
              metadata = ?
          WHERE id = ?
        SQL
        [normalized_status, current_loop_count + 1, JSON.generate(merged_metadata), run_id]
      )

      find_run(run_id)
    end

    def create_checkpoint(run_id:, summary:, metadata: {})
      id = SecureRandom.uuid
      execute(
        "INSERT INTO run_checkpoints (id, run_id, summary, metadata) VALUES (?, ?, ?, ?)",
        [id, run_id, summary, JSON.generate(metadata)]
      )
      rows("SELECT * FROM run_checkpoints WHERE id = ?", [id]).first
    end

    def latest_checkpoint(run_id)
      rows("SELECT * FROM run_checkpoints WHERE run_id = ? ORDER BY created_at DESC LIMIT 1", [run_id]).first
    end

    def list_checkpoints(run_id, limit: 20)
      rows(
        "SELECT * FROM run_checkpoints WHERE run_id = ? ORDER BY created_at DESC LIMIT ?",
        [run_id, limit]
      )
    end

    def reindex_embeddings(session_id: nil, entity_type: nil)
      counts = {
        plan_items_indexed: 0,
        journal_entries_indexed: 0,
        errors: 0
      }

      if entity_type.nil? || entity_type == "plan_item"
        sql = "SELECT id, description FROM plan_items"
        params = []
        if session_id
          sql += " WHERE session_id = ?"
          params << session_id
        end

        rows(sql, params).each do |item|
          if index_entity(entity_type: "plan_item", entity_id: item["id"], content: item["description"])
            counts[:plan_items_indexed] += 1
          else
            counts[:errors] += 1
          end
        end
      end

      if entity_type.nil? || entity_type == "journal_entry"
        sql = "SELECT id, content FROM journal_entries"
        params = []
        if session_id
          sql += " WHERE session_id = ?"
          params << session_id
        end

        rows(sql, params).each do |entry|
          if index_entity(entity_type: "journal_entry", entity_id: entry["id"], content: entry["content"])
            counts[:journal_entries_indexed] += 1
          else
            counts[:errors] += 1
          end
        end
      end

      counts
    end

    private

    def open_connection(path)
      db = if DuckDB::Database.respond_to?(:open)
             DuckDB::Database.open(path)
           else
             DuckDB::Database.new(path)
           end

      db.connect
    end

    def bootstrap!
      execute <<~SQL
        CREATE TABLE IF NOT EXISTS sessions (
          id VARCHAR PRIMARY KEY,
          goal TEXT,
          status VARCHAR DEFAULT 'active',
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      SQL

      execute <<~SQL
        CREATE TABLE IF NOT EXISTS plan_items (
          id VARCHAR PRIMARY KEY,
          session_id VARCHAR,
          description TEXT,
          embedding FLOAT[],
          is_completed BOOLEAN DEFAULT FALSE,
          FOREIGN KEY (session_id) REFERENCES sessions(id)
        )
      SQL

      execute <<~SQL
        CREATE TABLE IF NOT EXISTS journal_entries (
          id VARCHAR PRIMARY KEY,
          session_id VARCHAR,
          entry_type VARCHAR,
          content TEXT,
          metadata JSON,
          timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      SQL

      execute <<~SQL
        CREATE TABLE IF NOT EXISTS agent_runs (
          id VARCHAR PRIMARY KEY,
          session_id VARCHAR,
          agent_id VARCHAR,
          status VARCHAR,
          started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          ended_at TIMESTAMP,
          last_heartbeat_at TIMESTAMP,
          resume_token VARCHAR,
          FOREIGN KEY (session_id) REFERENCES sessions(id)
        )
      SQL

      execute <<~SQL
        CREATE TABLE IF NOT EXISTS run_checkpoints (
          id VARCHAR PRIMARY KEY,
          run_id VARCHAR,
          summary TEXT,
          metadata JSON,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          FOREIGN KEY (run_id) REFERENCES agent_runs(id)
        )
      SQL

      ensure_column("agent_runs", "loop_count INTEGER DEFAULT 0")
      ensure_column("agent_runs", "last_status_summary TEXT")
      ensure_column("agent_runs", "metadata JSON DEFAULT '{}'")

      bootstrap_vss!

      execute <<~SQL
        CREATE TABLE IF NOT EXISTS embeddings (
          id VARCHAR PRIMARY KEY,
          entity_type VARCHAR,
          entity_id VARCHAR,
          vector FLOAT[#{Config.embedding_dimensions}],
          model VARCHAR,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      SQL

      if @vss_enabled
        begin
          execute <<~SQL, nil, suppress_error_log: true
            CREATE INDEX IF NOT EXISTS embeddings_hnsw_cosine_idx
            ON embeddings USING HNSW (vector)
            WITH (metric = 'cosine')
          SQL
        rescue StandardError => e
          log_swallowed_error(
            event: "vss_index_create_skipped",
            exception: e
          )
          nil
        end
      end
    end

    def ensure_column(table_name, column_definition)
      column_name = column_definition.split.first
      existing = rows("PRAGMA table_info(#{table_name})")
      return if existing.any? { |row| run_value(row, "name") == column_name }

      execute("ALTER TABLE #{table_name} ADD COLUMN #{column_definition}")
    rescue StandardError => e
      log_swallowed_error(
        event: "ensure_column_failed",
        exception: e,
        extra: { table_name: table_name, column: column_name }
      )
      nil
    end

    def bootstrap_vss!
      execute("INSTALL vss", nil, suppress_error_log: true)
      execute("LOAD vss", nil, suppress_error_log: true)
      @vss_enabled = true
    rescue StandardError => e
      @vss_enabled = false
      @vss_error = e.message
      log_swallowed_error(
        event: "vss_bootstrap_failed",
        exception: e
      )
    end

    def index_entity(entity_type:, entity_id:, content:)
      vector = @embedder.embed(content)
      return false unless vector

      execute("DELETE FROM embeddings WHERE entity_type = ? AND entity_id = ?", [entity_type, entity_id])

      vector_literal = vector_sql_literal(vector)
      vector_cast = "CAST(#{vector_literal} AS FLOAT[#{Config.embedding_dimensions}])"
      execute(
        "INSERT INTO embeddings (id, entity_type, entity_id, vector, model) VALUES (?, ?, ?, #{vector_cast}, ?)",
        [SecureRandom.uuid, entity_type, entity_id, @embedder.model]
      )

      true
    rescue StandardError => e
      log_swallowed_error(
        event: "index_entity_failed",
        exception: e,
        extra: { entity_type: entity_type, entity_id: entity_id }
      )
      false
    end

    def lexical_journal_matches(query, limit:, session_id:)
      q = "%#{query}%"

      sql = "SELECT * FROM journal_entries WHERE content ILIKE ?"
      params = [q]
      if session_id
        sql += " AND session_id = ?"
        params << session_id
      end
      sql += " ORDER BY timestamp DESC LIMIT ?"
      params << limit

      rows(sql, params).each_with_index.map do |row, idx|
        row.merge(
          "recall_mode" => "lexical",
          "lexical_rank" => idx + 1,
          "semantic_score" => nil,
          "recall_score" => ((limit - idx).to_f / limit).round(6),
          "retrieval_rationale" => "Matched exact/near text in journal content"
        )
      end
    end

    def semantic_journal_matches(query, limit:, session_id:)
      vector = @embedder.embed(query)
      return [] unless vector

      vector_sql = casted_vector_sql(vector)
      sql = <<~SQL
        SELECT j.*, (1 - array_cosine_distance(e.vector, #{vector_sql})) AS semantic_score
        FROM embeddings e
        JOIN journal_entries j ON j.id = e.entity_id
        WHERE e.entity_type = 'journal_entry'
      SQL
      params = []
      if session_id
        sql += " AND j.session_id = ?"
        params << session_id
      end
      sql += " ORDER BY semantic_score DESC LIMIT ?"
      params << limit

      rows(sql, params).each do |row|
        row["recall_mode"] = "semantic"
        row["lexical_rank"] = nil
        row["recall_score"] = row["semantic_score"].to_f.round(6)
        row["retrieval_rationale"] = "Matched semantic vector similarity"
      end
    rescue StandardError => e
      log_swallowed_error(
        event: "semantic_recall_failed",
        exception: e
      )
      []
    end

    def hybrid_journal_matches(query, limit:, session_id:)
      lexical = lexical_journal_matches(query, limit: limit, session_id: session_id)
      semantic = semantic_journal_matches(query, limit: limit, session_id: session_id)

      merged = {}

      lexical.each do |row|
        id = row["id"]
        merged[id] = row.dup
      end

      semantic.each do |row|
        id = row["id"]
        existing = merged[id]
        if existing
          existing["semantic_score"] = row["semantic_score"]
          existing["recall_mode"] = "hybrid"
          lexical_bonus = existing["recall_score"].to_f * 0.25
          semantic_score = row["semantic_score"].to_f
          existing["recall_score"] = (semantic_score + lexical_bonus).round(6)
          existing["retrieval_rationale"] = "Combined lexical text match and semantic similarity"
        else
          copy = row.dup
          copy["recall_mode"] = "hybrid"
          copy["recall_score"] = copy["semantic_score"].to_f.round(6)
          copy["retrieval_rationale"] = "Semantic similarity with no lexical overlap"
          merged[id] = copy
        end
      end

      merged.values.sort_by { |row| -row["recall_score"].to_f }.first(limit)
    end

    def normalize_recall_mode(mode)
      value = mode.to_s.downcase
      return "lexical" if value == "lexical"
      return "semantic" if value == "semantic"

      "hybrid"
    end

    def normalize_run_status(status)
      normalized = status.to_s
      return normalized if RUN_STATUSES.include?(normalized)

      raise ArgumentError, "Invalid run status '#{status}'. Allowed: #{RUN_STATUSES.join(', ')}"
    end

    def merge_run_metadata(run, additional)
      existing_raw = run_value(run, "metadata")
      existing = parse_json(existing_raw)
      existing.merge(additional)
    end

    def run_value(record, key)
      record[key] || record[key.to_sym]
    end

    def parse_json(value)
      return {} if value.nil? || value == ""
      return value if value.is_a?(Hash)

      JSON.parse(value)
    rescue JSON::ParserError => e
      log_swallowed_error(
        event: "parse_json_failed",
        exception: e
      )
      {}
    end

    def casted_vector_sql(vector)
      "CAST(#{vector_sql_literal(vector)} AS FLOAT[#{Config.embedding_dimensions}])"
    end

    def vector_sql_literal(vector)
      values = vector.map { |v| format("%.10f", v.to_f) }
      "[#{values.join(',')}]"
    end

    def execute(sql, params = nil, suppress_error_log: false)
      with_db_lock(sql: sql, params: params, suppress_error_log: suppress_error_log) do
        if params
          @connection.execute(sql, *params)
        else
          @connection.execute(sql)
        end
      end
    end

    def rows(sql, params = nil, suppress_error_log: false)
      result = with_db_lock(sql: sql, params: params, suppress_error_log: suppress_error_log) do
        if params
          @connection.execute(sql, *params)
        else
          @connection.execute(sql)
        end
      end

      if result.respond_to?(:to_a)
        mapped_rows(result)
      else
        Array(result)
      end
    end

    def mapped_rows(result)
      rows = result.to_a
      return rows unless rows.first.is_a?(Array)

      columns = if result.respond_to?(:columns)
                  result.columns
                else
                  []
                end

      return rows if columns.empty?

      column_names = columns.map do |column|
        column.respond_to?(:name) ? column.name : column.to_s
      end

      rows.map { |row| column_names.zip(row).to_h }
    end

    def with_db_lock(sql:, params:, suppress_error_log:, &block)
      if Config.db_mutex_enabled?
        @db_mutex.synchronize(&block)
      else
        block.call
      end
    rescue DuckDB::Error => e
      raise if suppress_error_log

      warn(
        JSON.generate(
          event: "duckdb_error",
          error_class: e.class.name,
          message: e.message,
          sql: sql.to_s.gsub(/\s+/, " ").strip[0, 220],
          params_count: params ? params.length : 0,
          request_id: Thread.current[:gc_request_id],
          thread_id: Thread.current.object_id
        )
      )
      raise
    end

    def log_swallowed_error(event:, exception:, extra: {})
      warn(
        JSON.generate(
          {
            event: event,
            error_class: exception.class.name,
            message: exception.message,
            request_id: Thread.current[:gc_request_id],
            thread_id: Thread.current.object_id
          }.merge(extra)
        )
      )
    end
  end
end
