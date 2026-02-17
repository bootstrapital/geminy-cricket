# frozen_string_literal: true

require "spec_helper"

RSpec.describe GeminyCricket::Store do
  let(:db_path) { "db/test_store.duckdb" }
  let(:store) { GeminyCricket::Store.new(path: db_path) }

  before do
    FileUtils.rm_f(db_path)
  end

  after do
    FileUtils.rm_f(db_path)
  end

  describe "#bootstrap!" do
    it "creates the necessary tables" do
      # bootstrap! is called in initialize
      tables = store.send(:rows, "PRAGMA show_tables").map { |r| r["name"] }
      expect(tables).to include("sessions")
      expect(tables).to include("plan_items")
      expect(tables).to include("journal_entries")
    end
  end

  describe "#create_session" do
    it "persists a new session" do
      session = store.create_session(goal: "Test goal")
      expect(session["goal"]).to eq("Test goal")
      expect(session["id"]).not_to be_nil
    end
  end

  describe "#create_plan_item" do
    it "persists a plan item for a session" do
      session = store.create_session(goal: "Goal")
      item = store.create_plan_item(session_id: session["id"], description: "Step 1")
      expect(item["description"]).to eq("Step 1")
      expect(item["session_id"]).to eq(session["id"])
    end
  end

  describe "#create_journal_entry" do
    it "persists a journal entry" do
      session = store.create_session(goal: "Goal")
      entry = store.create_journal_entry(
        session_id: session["id"],
        entry_type: "reasoning",
        content: "Some thought"
      )
      expect(entry["content"]).to eq("Some thought")
      expect(entry["entry_type"]).to eq("reasoning")
    end
  end

  describe "mutex safety" do
    it "allows concurrent access when mutex is enabled" do
      session = store.create_session(goal: "Concurrency")
      threads = []
      5.times do |i|
        threads << Thread.new do
          store.create_journal_entry(
            session_id: session["id"],
            entry_type: "thread",
            content: "Thread #{i}"
          )
        end
      end
      threads.each(&:join)
      entries = store.list_journal_entries(session["id"])
      expect(entries.length).to eq(5)
    end
  end
end
