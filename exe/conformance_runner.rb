#!/usr/bin/env ruby
# frozen_string_literal: true

# The Ruby conformance runner.
#
# Reads one scenario as JSON on stdin, drives this SDK against the mock server
# the driver started, and prints one JSON report on stdout. See
# contract/harness/runners/README.md for the contract.
#
# Exits non-zero only if the runner itself broke. An SDK misbehaving is a report
# for the driver to judge, not a crash here.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "json"
require "marginfuse"

# The scenarios speak the wire's camelCase; this SDK speaks snake_case.
USAGE_KEYS = {
  "inputTokens" => :input_tokens,
  "outputTokens" => :output_tokens,
  "cachedInputTokens" => :cached_input_tokens,
  "cacheCreationTokens" => :cache_creation_tokens,
  "images" => :images,
  "audioSeconds" => :audio_seconds
}.freeze

PARAM_KEYS = {
  "customerId" => :customer_id,
  "eventId" => :event_id,
  "requestedModel" => :requested_model,
  "costUsd" => :cost_usd,
  "decisionId" => :decision_id,
  "feature" => :feature,
  "provider" => :provider,
  "model" => :model
}.freeze

def usage_from(raw)
  return {} unless raw.is_a?(Hash)

  raw.each_with_object({}) do |(key, value), out|
    mapped = USAGE_KEYS[key]
    out[mapped] = value if mapped
  end
end

def decision_json(decision)
  {
    "id" => decision.id,
    "action" => decision.action.to_s,
    "model" => decision.model,
    "provider" => decision.provider,
    "topupContext" => decision.topup_context,
    "degraded" => decision.degraded?,
    "degradedReason" => decision.degraded_reason
  }
end

scenario = JSON.parse($stdin.read)
provider_calls = []
on_error_contexts = []

options = {
  api_key: ENV.fetch("MARGINFUSE_API_KEY", ""),
  base_url: ENV.fetch("MARGINFUSE_BASE_URL", ""),
  on_error: ->(_error, context) { on_error_contexts << context }
}
timeout_ms = scenario.dig("options", "timeoutMs")
options[:timeout] = timeout_ms / 1000.0 if timeout_ms

mf = MarginFuse::Client.new(**options)

params = (scenario["params"] || {}).each_with_object({}) do |(key, value), out|
  if key == "usage"
    out[:usage] = usage_from(value)
  elsif key == "expectedUsage"
    out[:expected_usage] = usage_from(value)
  elsif key == "outcome"
    out[:outcome] = value.to_sym
  elsif PARAM_KEYS[key]
    out[PARAM_KEYS[key]] = value
  end
end

report = { "outcome" => "returned" }

begin
  case scenario["action"]
  when "decide"
    report["result"] = decision_json(mf.decide(**params))
  when "track"
    mf.track(**params)
  when "acknowledge"
    mf.acknowledge(params[:decision_id], scenario["params"]["acknowledgment"].to_sym)
  when "guard"
    spec = scenario["provider"] || {}
    outcome = mf.guard(**params) do |decision|
      provider_calls << { "model" => decision.model, "provider" => decision.provider }
      raise "provider exploded" if spec["throws"]

      { result: "ok", usage: usage_from(spec["usage"]) }
    end
    # Only the discriminant and the decision travel; the application's own
    # result means nothing to another language.
    report["result"] = {
      "kind" => outcome.kind.to_s,
      "decision" => decision_json(outcome.decision)
    }
  else
    warn "unknown action #{scenario['action']}"
    exit 1
  end
rescue Exception => e # rubocop:disable Lint/RescueException
  report["outcome"] = "threw"
  report["threw"] = e.message
end

# Always flush, including after a raise: the driver asserts on what the SDK
# sent, and guard records the attempt before it re-raises.
mf.flush

report["providerCalls"] = provider_calls
report["onErrorContexts"] = on_error_contexts
puts JSON.generate(report)
