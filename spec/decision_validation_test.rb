# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "marginfuse"

class DecisionValidationTest < Minitest::Test
  INVALID = [
    {}, { "action" => "unknown" }, { "action" => "allow", "model" => 7 },
    { "action" => "allow", "provider" => [] }, { "action" => "allow", "model" => " " },
    { "action" => "allow", "provider" => " " }, { "action" => "downgrade" },
    { "action" => "allow", "degraded" => "false" }, { "action" => "block", "id" => 7 },
    { "action" => "allow", "model" => nil }, [], nil
  ].freeze

  INVALID.each_with_index do |payload, index|
    define_method("test_malformed_success_fails_open_#{index}") do
      errors = []
      client = MarginFuse.new(api_key: "mf_test", on_error: lambda { |_error, context|
        errors << context
      })
      response = Struct.new(:code, :body).new("200", JSON.generate(payload))
      client.define_singleton_method(:post) { |*_args| response }
      decision = client.decide(customer_id: "customer", provider: "openai", model: "gpt-4.1")
      assert_equal :allow, decision.action
      assert_equal "gpt-4.1", decision.model
      assert_equal "openai", decision.provider
      assert_equal true, decision.degraded
      assert_nil decision.id
      assert_equal ["decide"], errors
    end
  end

  def test_valid_block_without_id_still_blocks
    client = MarginFuse.new(api_key: "mf_test")
    response = Struct.new(:code, :body).new("200", '{"action":"block"}')
    client.define_singleton_method(:post) { |*_args| response }
    decision = client.decide(customer_id: "customer", provider: "openai", model: "gpt-4.1")
    assert_equal :block, decision.action
    assert_equal false, decision.degraded
  end
end
