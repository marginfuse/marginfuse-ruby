# frozen_string_literal: true

require_relative "lib/marginfuse/version"

Gem::Specification.new do |spec|
  spec.name = "marginfuse"
  spec.version = MarginFuse::VERSION
  spec.authors = ["Pemira Labs"]
  spec.license = "MIT"

  spec.summary = "AI profitability guardrails: connect revenue to per-request AI cost."
  spec.description = <<~TEXT.strip
    MarginFuse server-side SDK. Connect revenue to per-request AI cost, see gross
    margin per customer, and stop loss-making requests before they run. Sends
    usage metadata only, never prompts or responses.
  TEXT

  spec.homepage = "https://marginfuse.com"
  spec.metadata = {
    "homepage_uri" => "https://marginfuse.com",
    "documentation_uri" => "https://marginfuse.com/docs",
    "source_code_uri" => "https://github.com/marginfuse/marginfuse-ruby",
    "bug_tracker_uri" => "https://github.com/marginfuse/marginfuse-ruby/issues",
    "changelog_uri" => "https://github.com/marginfuse/marginfuse-ruby/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  # Ruby 3.2 is the oldest release still receiving security fixes, and the
  # oldest the development toolchain installs on.
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  # No runtime dependencies. net/http and json are in the standard library, and
  # a gem that pulls in an HTTP client forces its version on every application
  # that bundles it.
end
