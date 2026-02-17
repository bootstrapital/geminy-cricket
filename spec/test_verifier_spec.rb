# frozen_string_literal: true

require "spec_helper"

RSpec.describe GeminyCricket::TestVerifier do
  let(:scope) { "spec/models/user_spec.rb" }
  let(:verifier) { GeminyCricket::TestVerifier.new(scope: scope) }

  describe "#detect_framework" do
    it "defaults to rspec" do
      expect(verifier.send(:detect_framework)).to eq("rspec")
    end
  end

  describe "#verify_rspec" do
    let(:rspec_json) do
      {
        "examples" => [
          { "status" => "passed", "full_description" => "User works" },
          {
            "status" => "failed",
            "full_description" => "User fails",
            "exception" => {
              "message" => "Expected true to be false",
              "backtrace" => ["spec/models/user_spec.rb:10:in `block'"]
            }
          }
        ],
        "summary_line" => "2 examples, 1 failure"
      }
    end

    it "parses failures into a chirp" do
      allow(verifier).to receive(:run_rspec).and_return(rspec_json)
      allow(verifier).to receive(:extract_snippet).and_return("line 10 snippet")

      result = verifier.send(:verify_rspec)
      expect(result[:status]).to eq("failed")
      expect(result[:chirp][:exception]).to eq("Expected true to be false")
      expect(result[:chirp][:file]).to eq("spec/models/user_spec.rb")
      expect(result[:chirp][:line]).to eq(10)
    end
  end

  describe "#verify_minitest" do
    let(:minitest_output) do
      <<~OUT
        Run options: --seed 1234
        # Running:
        F
        Finished in 0.001s, 1000.0 tests/s.
          1) Failure:
        UserTest#test_fail [test/models/user_test.rb:5]:
        Expected: true
          Actual: false

        1 runs, 1 assertions, 1 failures, 0 errors, 0 skips
      OUT
    end

    it "parses minitest failures" do
      allow(verifier).to receive(:run_minitest).and_return([minitest_output, double(success?: false)])
      allow(verifier).to receive(:extract_snippet).and_return("line 5 snippet")

      result = verifier.send(:verify_minitest)
      expect(result[:status]).to eq("failed")
      expect(result[:chirp][:file]).to eq("test/models/user_test.rb")
      expect(result[:chirp][:line]).to eq(5)
    end
  end
end
