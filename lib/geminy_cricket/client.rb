# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module GeminyCricket
  class Client
    def initialize(base_url: Config.server_url, timeout_seconds: Config.server_timeout_seconds)
      @base_url = base_url
      @timeout_seconds = timeout_seconds
    end

    def dispatch(tool, args = {})
      uri = URI.join(@base_url.end_with?("/") ? @base_url : "#{@base_url}/", "tool")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @timeout_seconds
      http.read_timeout = @timeout_seconds

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["X-GC-API-Key"] = Config.tool_api_key if Config.tool_api_auth_required?
      req.body = JSON.generate({ tool: tool, args: args })

      res = http.request(req)
      parsed = JSON.parse(res.body)

      unless parsed["ok"]
        err = parsed["error"] || {}
        raise Supervisor::ToolError.new(
          err["message"] || "Supervisor request failed",
          code: err["code"] || "server_error",
          retryable: err["retryable"] || false,
          details: err["details"] || {}
        )
      end

      parsed.fetch("data")
    rescue JSON::ParserError => e
      raise Supervisor::ToolError.new("Invalid supervisor response JSON: #{e.message}", code: "server_error", retryable: true)
    rescue Errno::ECONNREFUSED, Errno::EPERM, Errno::EHOSTUNREACH, SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise Supervisor::ToolError.new(
        "Cannot reach Geminy Cricket server at #{@base_url}. Start with: bundle exec ruby bin/geminy-cricket-server",
        code: "server_unavailable",
        retryable: true,
        details: { cause: e.class.name }
      )
    end

    def healthy?
      uri = URI.join(@base_url.end_with?("/") ? @base_url : "#{@base_url}/", "health")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 1
      http.read_timeout = 1

      res = http.get(uri.request_uri)
      return false unless res.code.to_i == 200

      parsed = JSON.parse(res.body)
      parsed["ok"] == true
    rescue StandardError
      false
    end
  end
end
