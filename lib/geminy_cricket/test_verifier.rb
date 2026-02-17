# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

module GeminyCricket
  class TestVerifier
    SUPPORTED_FRAMEWORKS = %w[auto rspec minitest].freeze

    def initialize(scope:, framework: "auto", snippet_radius: Config.snippet_radius)
      @scope = scope
      @framework = framework.to_s
      @snippet_radius = snippet_radius
      validate_framework!
    end

    def verify
      framework_used = detect_framework
      result = case framework_used
               when "rspec"
                 verify_rspec
               when "minitest"
                 verify_minitest
               else
                 raise "Unknown framework '#{framework_used}'"
               end

      result[:framework_used] = framework_used
      result
    rescue StandardError => e
      log_swallowed_error(
        event: "test_verifier_verify_failed",
        exception: e,
        extra: { scope: @scope.to_s, framework: @framework.to_s }
      )
      {
        status: "error",
        summary: "Unable to run tests",
        framework_used: detect_framework,
        error: e.message
      }
    end

    private

    def validate_framework!
      return if SUPPORTED_FRAMEWORKS.include?(@framework)

      raise ArgumentError, "framework must be one of #{SUPPORTED_FRAMEWORKS.join(', ')}"
    end

    def detect_framework
      return @framework unless @framework == "auto"

      return "rspec" if Dir.exist?("spec") && !Dir.glob("spec/**/*_spec.rb").empty?
      return "minitest" if Dir.exist?("test") && !Dir.glob("test/**/*_test.rb").empty?

      "rspec"
    end

    def verify_rspec
      payload = run_rspec
      failures = Array(payload["examples"]).select { |example| example["status"] == "failed" }

      if failures.empty?
        {
          status: "passed",
          summary: payload["summary_line"] || "All tests passing",
          total_examples: payload.dig("summary", "example_count")
        }
      else
        first_failure = failures.first
        location = parse_rspec_failure_location(first_failure)

        {
          status: "failed",
          summary: payload["summary_line"] || "Tests failed",
          chirp: {
            scope: @scope,
            failing_example: first_failure["full_description"],
            file: location[:file],
            line: location[:line],
            snippet: location[:snippet],
            exception: first_failure.dig("exception", "message"),
            backtrace: Array(first_failure.dig("exception", "backtrace")).first(5)
          }
        }
      end
    end

    def verify_minitest
      output, status = run_minitest
      parsed = parse_minitest_failure(output)

      if status.success? && parsed.nil?
        {
          status: "passed",
          summary: extract_minitest_summary(output) || "All tests passing"
        }
      elsif parsed
        {
          status: "failed",
          summary: extract_minitest_summary(output) || "Tests failed",
          chirp: parsed
        }
      else
        {
          status: "error",
          summary: "Unable to parse minitest output",
          error: output.lines.last.to_s.strip
        }
      end
    end

    def run_rspec
      Tempfile.create(["rspec", ".json"]) do |file|
        cmd = ["bundle", "exec", "rspec", @scope.to_s, "--format", "json", "--out", file.path]
        stdout, stderr, status = Open3.capture3(*cmd)

        unless File.exist?(file.path) && File.size?(file.path)
          raise "RSpec did not produce JSON output. stdout=#{stdout} stderr=#{stderr} exit=#{status.exitstatus}"
        end

        data = JSON.parse(File.read(file.path))
        data["_command"] = cmd.join(" ")
        data
      end
    end

    def run_minitest
      files = resolve_minitest_files(@scope)
      raise "No minitest files found for scope '#{@scope}'" if files.empty?

      runner = <<~'RB'
        require "minitest"
        require "minitest/autorun"
        ARGV.each { |f| require File.expand_path(f) }
      RB

      cmd = ["bundle", "exec", "ruby", "-Itest", "-e", runner, *files]
      stdout, stderr, status = Open3.capture3(*cmd)
      ["#{stdout}\n#{stderr}", status]
    end

    def resolve_minitest_files(scope)
      return Dir.glob("test/**/*_test.rb").sort if scope.to_s.strip.empty? || scope.to_s == "test"

      if File.directory?(scope)
        return Dir.glob(File.join(scope, "**/*_test.rb")).sort
      end

      if File.file?(scope)
        return [scope]
      end

      Dir.glob(scope.to_s).select { |path| File.file?(path) }
    end

    def parse_rspec_failure_location(failure)
      backtrace = Array(failure.dig("exception", "backtrace"))
      candidate = backtrace.find { |line| line.include?(":") }
      file, line = candidate.to_s.split(":", 3)
      line_no = line.to_i

      {
        file: file,
        line: line_no.zero? ? nil : line_no,
        snippet: extract_snippet(file, line_no)
      }
    end

    def parse_minitest_failure(output)
      lines = output.lines.map(&:rstrip)
      failure_start = lines.find_index { |line| line.match?(/^\s*\d+\)\s+(Failure|Error):/) }
      return nil unless failure_start

      heading = lines[failure_start]
      failing_example = lines[failure_start + 1].to_s.strip

      location = parse_minitest_location(lines, failure_start)
      exception = parse_minitest_exception(lines, failure_start)
      backtrace = parse_minitest_backtrace(lines, failure_start)

      {
        scope: @scope,
        failing_example: failing_example.empty? ? heading.strip : failing_example,
        file: location[:file],
        line: location[:line],
        snippet: extract_snippet(location[:file], location[:line]),
        exception: exception,
        backtrace: backtrace.first(5)
      }
    end

    def parse_minitest_location(lines, start_idx)
      lookahead = lines[(start_idx + 1)..(start_idx + 8)] || []

      lookahead.each do |line|
        if (match = line.match(/\[(.+):(\d+)\]/))
          return { file: match[1], line: match[2].to_i }
        end

        if (match = line.match(/^\s*(.+):(\d+):/))
          return { file: match[1], line: match[2].to_i }
        end
      end

      { file: nil, line: nil }
    end

    def parse_minitest_exception(lines, start_idx)
      lookahead = lines[(start_idx + 2)..(start_idx + 10)] || []
      message_line = lookahead.find { |line| !line.strip.empty? && !line.match?(/^\s+.+:\d+:/) }
      message_line&.strip
    end

    def parse_minitest_backtrace(lines, start_idx)
      lookahead = lines[(start_idx + 1)..(start_idx + 15)] || []
      lookahead.select { |line| line.match?(/^\s+.+:\d+:/) }.map(&:strip)
    end

    def extract_minitest_summary(output)
      output.lines.reverse_each.find { |line| line.include?("runs") && line.include?("assertions") }&.strip
    end

    def extract_snippet(file, line_no)
      return nil unless file && line_no.to_i.positive? && File.file?(file)

      line_no = line_no.to_i
      lines = File.readlines(file, chomp: true)
      start_idx = [line_no - @snippet_radius - 1, 0].max
      end_idx = [line_no + @snippet_radius - 1, lines.length - 1].min

      (start_idx..end_idx).map do |idx|
        marker = (idx + 1 == line_no) ? ">" : " "
        format("%s %4d | %s", marker, idx + 1, lines[idx])
      end.join("\n")
    rescue StandardError => e
      log_swallowed_error(
        event: "test_verifier_extract_snippet_failed",
        exception: e,
        extra: { file: file.to_s, line_no: line_no.to_i }
      )
      nil
    end

    def log_swallowed_error(event:, exception:, extra: {})
      warn(
        JSON.generate(
          {
            event: event,
            error_class: exception.class.name,
            message: exception.message
          }.merge(extra)
        )
      )
    end
  end
end
