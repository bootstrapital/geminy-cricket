# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe GeminyCricket::DashboardApp do
  include Rack::Test::Methods

  def app
    # Disable rack protection for tests to avoid Host not permitted errors
    GeminyCricket::DashboardApp.set :protection, false
    GeminyCricket::DashboardApp
  end

  let(:db_path) { "db/test_dashboard.duckdb" }

  before do
    header "Host", "127.0.0.1"
    FileUtils.rm_f(db_path)
    ENV["GC_DB_PATH"] = db_path
    # Clear instances to ensure new store with test DB path
    GeminyCricket::DashboardApp.instance_variable_set(:@store_instance, nil)
    GeminyCricket::DashboardApp.instance_variable_set(:@supervisor_instance, nil)
  end

  after do
    FileUtils.rm_f(db_path)
  end

  describe "GET /health" do
    it "returns ok" do
      get "/health"
      expect(last_response).to be_ok
      expect(JSON.parse(last_response.body)["ok"]).to be true
    end
  end

  describe "dashboard template escaping" do
    it "escapes journal content in rendered HTML" do
      session = GeminyCricket::DashboardApp.store_instance.create_session(goal: "xss")
      GeminyCricket::DashboardApp.store_instance.create_journal_entry(
        session_id: session["id"],
        entry_type: "test_failure",
        content: "<script>alert('xss')</script>"
      )

      get "/journal"

      expect(last_response).to be_ok
      expect(last_response.body).to include("&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;")
      expect(last_response.body).not_to include("<script>alert('xss')</script>")
    end
  end

  describe "POST /tool" do
    context "without auth" do
      before { ENV["GC_TOOL_API_KEY"] = nil }

      it "allows the request" do
        post "/tool", JSON.generate({ tool: "gc_start", args: { goal: "test" } })
        expect(last_response).to be_ok
      end
    end

    context "with auth enabled" do
      before { ENV["GC_TOOL_API_KEY"] = "secret-key" }
      after { ENV["GC_TOOL_API_KEY"] = nil }

      it "rejects unauthorized requests" do
        post "/tool", JSON.generate({ tool: "gc_start", args: { goal: "test" } })
        expect(last_response.status).to eq(401)
      end

      it "allows authorized requests" do
        header "X-GC-API-Key", "secret-key"
        post "/tool", JSON.generate({ tool: "gc_start", args: { goal: "test" } })
        expect(last_response).to be_ok
      end
    end
  end
end
