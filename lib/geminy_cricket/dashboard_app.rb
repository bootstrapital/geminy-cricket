# frozen_string_literal: true

require "sinatra/base"
require "json"
require "rack/utils"
require "securerandom"
require "slim"

module GeminyCricket
  class DashboardApp < Sinatra::Base
    set :views, File.expand_path("../../dashboard/views", __dir__)
    set :slim, disable_escape: false

    class << self
      def store_instance
        @store_instance ||= Store.new
      end

      def supervisor_instance
        @supervisor_instance ||= Supervisor.new(store: store_instance)
      end
    end

    before do
      Thread.current[:gc_request_id] = SecureRandom.hex(8)
      env["gc.started_at"] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    after do
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - env["gc.started_at"]) * 1000.0).round(2)
      logger.info(
        JSON.generate(
          event: "http_request",
          request_id: Thread.current[:gc_request_id],
          method: request.request_method,
          path: request.path_info,
          status: response.status,
          elapsed_ms: elapsed_ms,
          thread_id: Thread.current.object_id
        )
      )
      Thread.current[:gc_request_id] = nil
    end

    helpers do
      def store
        self.class.store_instance
      end

      def supervisor
        self.class.supervisor_instance
      end

      def tool_auth_required?
        Config.tool_api_auth_required?
      end

      def authorized_tool_request?
        return true unless tool_auth_required?

        presented = request.env["HTTP_X_GC_API_KEY"].to_s
        expected = Config.tool_api_key
        return false if presented.empty? || expected.empty?
        return false unless presented.bytesize == expected.bytesize

        Rack::Utils.secure_compare(presented, expected)
      end
    end

    get "/" do
      @session = store.latest_active_session
      @plan_items = @session ? store.list_plan_items(@session["id"]) : []
      @entries = @session ? store.list_journal_entries(@session["id"]) : []
      @run = @session ? store.latest_run_for_session(@session["id"]) : nil
      @checkpoint = @run ? store.latest_checkpoint(@run["id"]) : nil
      slim :index
    end

    get "/health" do
      content_type :json
      session = store.latest_active_session
      run = session ? store.latest_run_for_session(session["id"]) : nil

      {
        ok: true,
        active_session_id: session && session["id"],
        latest_run_id: run && run["id"],
        latest_run_status: run && run["status"],
        recall_backend: store.recall_backend_status,
        runtime: {
          db_mutex_enabled: Config.db_mutex_enabled?,
          tool_auth_required: tool_auth_required?,
          puma_min_threads: Config.puma_min_threads,
          puma_max_threads: Config.puma_max_threads
        }
      }.to_json
    end

    post "/tool" do
      content_type :json
      unless authorized_tool_request?
        status 401
        return {
          ok: false,
          error: {
            code: "unauthorized",
            message: "Missing or invalid X-GC-API-Key",
            retryable: false
          }
        }.to_json
      end

      request.body.rewind if request.body.respond_to?(:rewind)
      body = request.body.read
      payload = JSON.parse(body)
      tool = payload.fetch("tool")
      args = payload.fetch("args", {})

      result = supervisor.dispatch(tool, args)
      { ok: true, data: result }.to_json
    rescue JSON::ParserError => e
      status 400
      { ok: false, error: { code: "invalid_json", message: e.message, retryable: false } }.to_json
    rescue Supervisor::ToolError => e
      status 422
      { ok: false, error: e.to_h }.to_json
    rescue KeyError => e
      status 422
      { ok: false, error: { code: "invalid_arguments", message: e.message, retryable: false } }.to_json
    rescue StandardError => e
      logger.error(
        JSON.generate(
          event: "tool_internal_error",
          request_id: Thread.current[:gc_request_id],
          tool: (payload.is_a?(Hash) ? payload["tool"] : nil),
          error_class: e.class.name,
          message: e.message,
          backtrace: Array(e.backtrace).first(5)
        )
      )
      status 500
      { ok: false, error: { code: "internal_error", message: e.message, retryable: true } }.to_json
    end

    get "/journal" do
      content_type "text/html"
      session = store.latest_active_session
      entries = session ? store.list_journal_entries(session["id"]) : []
      slim :_journal, layout: false, locals: { entries: entries }
    end

    get "/plan" do
      content_type "text/html"
      session = store.latest_active_session
      plan_items = session ? store.list_plan_items(session["id"]) : []
      slim :_plan, layout: false, locals: { plan_items: plan_items }
    end

    get "/run" do
      content_type "text/html"
      session = store.latest_active_session
      run = session ? store.latest_run_for_session(session["id"]) : nil
      checkpoint = run ? store.latest_checkpoint(run["id"]) : nil
      slim :_run, layout: false, locals: { run: run, checkpoint: checkpoint }
    end
  end
end
