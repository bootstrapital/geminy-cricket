# frozen_string_literal: true

require_relative "lib/geminy_cricket/version"

Gem::Specification.new do |spec|
  spec.name = "geminy-cricket"
  spec.version = GeminyCricket::VERSION
  spec.authors = ["Geminy Cricket Contributors"]
  spec.summary = "Supervisor server for test-driven agent workflows"
  spec.license = "MIT"
  spec.homepage = "https://github.com/bootstrapital/geminy-cricket"
  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir.glob("{bin,lib,dashboard}/**/*") + %w[README.md LICENSE]
  spec.bindir = "bin"
  spec.executables = ["geminy-cricket", "geminy-cricket-mcp", "geminy-cricket-server"]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "duckdb", "~> 1.1"
  spec.add_runtime_dependency "informers", "~> 1.2"
  spec.add_runtime_dependency "puma", "~> 7.0"
  spec.add_runtime_dependency "rackup", "~> 2.0"
  spec.add_runtime_dependency "sinatra", "~> 4.0"
end
