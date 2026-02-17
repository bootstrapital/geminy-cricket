# frozen_string_literal: true

require "spec_helper"

RSpec.describe GeminyCricket::Supervisor do
  let(:db_path) { "db/test_supervisor.duckdb" }
  let(:store) { GeminyCricket::Store.new(path: db_path) }
  let(:supervisor) { GeminyCricket::Supervisor.new(store: store) }

  before do
    FileUtils.rm_f(db_path)
  end

  after do
    FileUtils.rm_f(db_path)
  end

  describe "#dispatch" do
    context "gc_start" do
      it "creates a session and returns its ID" do
        result = supervisor.dispatch("gc_start", { "goal" => "Build a rocket" })
        expect(result[:session_id]).not_to be_nil
        expect(result[:goal]).to eq("Build a rocket")
      end
    end

    context "gc_plan_step" do
      it "adds a step to the active session" do
        supervisor.dispatch("gc_start", { "goal" => "Plan" })
        result = supervisor.dispatch("gc_plan_step", { "desc" => "Step 1" })
        expect(result[:plan_item]["description"]).to eq("Step 1")
      end

      it "raises error if no session exists" do
        expect do
          supervisor.dispatch("gc_plan_step", { "desc" => "Fail" })
        end.to raise_error(GeminyCricket::Supervisor::ToolError, /No active session/)
      end
    end

    context "gc_recall" do
      it "returns matches from the journal" do
        supervisor.dispatch("gc_start", { "goal" => "Recall" })
        store.create_journal_entry(
          session_id: supervisor.instance_variable_get(:@active_session_id),
          entry_type: "reasoning",
          content: "Secret code is 1234"
        )

        result = supervisor.dispatch("gc_recall", { "query" => "Secret" })
        expect(result[:matches].any? { |m| m["content"].include?("1234") }).to be true
      end
    end
  end

  describe "session resolution" do
    it "resolves from run_id" do
      session = store.create_session(goal: "Run test")
      run = store.create_agent_run(session_id: session["id"], agent_id: "agent-1")

      result = supervisor.dispatch("gc_checkpoint", { "run_id" => run["id"], "summary" => "Checked" })
      expect(result[:session_id]).to eq(session["id"])
    end
  end
end
