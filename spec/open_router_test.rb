# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "marginfuse"

# Driven entirely by contract/conformance/gateway-vectors.json, which every SDK
# in every language reads.
#
# Assertions written here instead would be a second copy of the truth, and this
# SDK would slowly stop agreeing with the others. To add a case, edit the vector
# file, not this test.
class OpenRouterVectorTest < Minitest::Test
  DECIMAL = /\A\d+(\.\d+)?\z/

  # camelCase in the vectors, snake_case in this SDK.
  WIRE = {
    input_tokens: "inputTokens",
    output_tokens: "outputTokens",
    cached_input_tokens: "cachedInputTokens",
    cache_creation_tokens: "cacheCreationTokens",
    images: "images",
    audio_seconds: "audioSeconds"
  }.freeze

  def self.cases
    @cases ||= begin
      path = File.expand_path("../contract/conformance/gateway-vectors.json", __dir__)
      JSON.parse(File.read(path)).fetch("adapters").fetch("fromOpenRouter").fetch("cases")
    end
  end

  def run_case(kase)
    kase["omitInput"] ? MarginFuse::OpenRouter.from : MarginFuse::OpenRouter.from(kase["input"])
  end

  # Only the fields the adapter actually set, in the vectors' wire names.
  def produced(result)
    result.fetch(:usage).each_with_object({}) { |(key, value), out| out[WIRE.fetch(key)] = value }
  end

  cases.each_with_index do |kase, index|
    define_method("test_vector_#{index}_#{kase['name'].gsub(/\W+/, '_')}") do
      result = run_case(kase)
      expected = kase.fetch("expected")

      assert_equal expected.fetch("usage"), produced(result), "usage for #{kase['name']}"

      if expected.key?("costUsd")
        assert_equal expected["costUsd"], result[:cost_usd], "costUsd for #{kase['name']}"
      else
        # Absent must mean absent, not present-and-zero: omitting the cost lets
        # MarginFuse price the call, where "0" would claim it was free.
        refute result.key?(:cost_usd), "costUsd should have been omitted for #{kase['name']}"
      end
    end
  end

  def test_never_produces_a_cost_the_api_would_reject
    # The decimal-string pattern from the API's own schema. Exponent notation is
    # the failure this guards, and it is silent everywhere else.
    self.class.cases.each do |kase|
      cost = run_case(kase)[:cost_usd]
      next if cost.nil?

      assert_match DECIMAL, cost, "#{kase['name']}: #{cost}"
    end
  end

  def test_contract_version_matches_the_pinned_contract
    # The exported contract version has to be the one this build was actually
    # verified against, or it is a claim rather than a fact.
    path = File.expand_path("../contract/conformance/behavior-scenarios.json", __dir__)
    pinned = JSON.parse(File.read(path)).fetch("version")

    assert_equal pinned, MarginFuse::CONTRACT_VERSION
  end
end
