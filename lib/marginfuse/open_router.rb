# frozen_string_literal: true

module MarginFuse
  # OpenRouter helper.
  #
  # OpenRouter returns a +usage+ object carrying the provider-final +cost+.
  # Forwarding it is what makes an OpenRouter integration exact rather than
  # estimated: MarginFuse cannot know what a gateway charged, because routing,
  # fees and BYOK terms are not visible in a usage event.
  #
  # Two details this helper exists to get right, both of which silently misstate
  # margin when hand-rolled:
  #
  # 1. +prompt_tokens+ is the TOTAL input count. Cached reads and cache writes
  #    are already inside it, and MarginFuse prices those as three separate
  #    charges and adds them up, so passing the total through charges every
  #    cached token twice at the full uncached rate.
  # 2. +cost+ is a Float, and +to_s+ renders small ones in exponent notation
  #    ("1.2e-07"), which the API rejects as a decimal string.
  module OpenRouter
    module_function

    # Maps an OpenRouter +usage+ object to MarginFuse keyword arguments.
    #
    #   r = client.chat(...)
    #   mf.track(customer_id: cid, provider: "openrouter", model: model,
    #            **MarginFuse::OpenRouter.from(r["usage"]))
    #
    # +:cost_usd+ is omitted when the response carried no cost, which lets the
    # event fall through to MarginFuse's own pricing instead of claiming a $0
    # charge.
    #
    # @return [Hash]
    def from(usage = nil)
      source = usage.is_a?(Hash) ? usage : {}
      details = source["prompt_tokens_details"] || source[:prompt_tokens_details]
      details = {} unless details.is_a?(Hash)

      cached = to_int(details["cached_tokens"] || details[:cached_tokens])
      cache_writes = to_int(details["cache_write_tokens"] || details[:cache_write_tokens])
      # What is left after the cached parts is what was billed at the full input
      # rate. Clamped at zero so a provider reporting these differently degrades
      # to "no fresh input" rather than a negative charge.
      prompt = to_int(source["prompt_tokens"] || source[:prompt_tokens])
      fresh = [0, prompt - cached - cache_writes].max
      completion = to_int(source["completion_tokens"] || source[:completion_tokens])

      mapped = {}
      mapped[:input_tokens] = fresh if fresh.positive?
      mapped[:output_tokens] = completion if completion.positive?
      mapped[:cached_input_tokens] = cached if cached.positive?
      mapped[:cache_creation_tokens] = cache_writes if cache_writes.positive?

      out = { usage: mapped }
      cost = source["cost"] || source[:cost]
      return out unless cost.is_a?(Numeric) && !cost.is_a?(Complex)
      return out if cost.respond_to?(:nan?) && cost.nan?
      return out if cost.respond_to?(:infinite?) && cost.infinite?
      return out if cost.negative?

      out[:cost_usd] = credits_to_usd(cost)
      out
    end

    def to_int(value)
      return 0 unless value.is_a?(Numeric) && !value.is_a?(Complex)
      return 0 if value.respond_to?(:nan?) && value.nan?
      return 0 if value.respond_to?(:infinite?) && value.infinite?
      return 0 unless value.positive?

      value.round
    end

    # OpenRouter credits (1 credit = 1 USD) as a decimal string the API takes.
    #
    # Fixed point to nano precision: +to_s+ emits exponent notation for the
    # small costs cheap models produce, and money below a nano cannot be
    # represented at all, so it rounds down rather than pretending otherwise.
    def credits_to_usd(cost)
      # Formatted to ten decimals and then truncated to nine, rather than
      # rounded: money below a nano cannot be represented, so it rounds down
      # instead of inventing precision it does not have.
      #
      # bigdecimal would read more clearly and stopped being a default gem in
      # Ruby 3.4, so requiring it would quietly turn this into a package with a
      # runtime dependency. Kernel#format is core.
      text = format("%.10f", cost)[0..-2]
      text = text.sub(/\.?0+\z/, "") if text.include?(".")
      text.empty? || text == "-0" ? "0" : text
    end
  end
end
