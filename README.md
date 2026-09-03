# marginfuse

[![Gem](https://img.shields.io/gem/v/marginfuse)](https://rubygems.org/gems/marginfuse)
[![ci](https://github.com/marginfuse/marginfuse-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/marginfuse/marginfuse-ruby/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Server-side SDK for [MarginFuse](https://marginfuse.com): profitability
guardrails for AI SaaS. Connect revenue to per-request AI cost, see gross margin
per customer, and stop loss-making requests before they run.

- **Metadata only, by construction.** The event shape has no field for prompts
  or responses, so they cannot be sent. Not a policy, an absence.
- **Never breaks your app.** It does not raise into your code, and it does not
  block your request on MarginFuse being up. If MarginFuse is unreachable, your
  requests proceed unchanged.
- **Zero dependencies.** Standard library only, Ruby 3.2+.

> **Server side only.** This SDK carries a secret API key. Never ship it in a
> desktop or mobile application, or anything else a user can read.

## Install

```bash
bundle add marginfuse
```

## Track an AI call

Monitoring. One call after each AI request, metadata only.

```ruby
require "marginfuse"

mf = MarginFuse.new(api_key: ENV.fetch("MARGINFUSE_KEY"))

response = client.chat(model: "gpt-4.1", messages: messages)

mf.track(
  customer_id: "cus_8x2m91",   # your Stripe customer id, or your own
  feature: "ai_chat",
  provider: "openai",
  model: "gpt-4.1",
  usage: {
    input_tokens: response.usage.prompt_tokens,
    output_tokens: response.usage.completion_tokens
  }
)
```

`track` returns immediately and sends on a background thread with retries. In a
rake task, a Sidekiq job or a script, call `mf.flush` before the process exits,
or the last events go with it.

## Guard a call

Protection. Ask before the call runs, and act on the answer.

```ruby
outcome = mf.guard(
  customer_id: "cus_8x2m91",
  feature: "ai_chat",
  provider: "openai",
  model: "gpt-4.1"
) do |decision|
  # decision.model is the one to call: a downgrade verdict changes it.
  response = client.chat(model: decision.model, messages: messages)
  {
    result: response,
    usage: {
      input_tokens: response.usage.prompt_tokens,
      output_tokens: response.usage.completion_tokens
    }
  }
end

case outcome.kind
when :completed then use(outcome.result)
when :topup_required then show_topup(outcome.decision.topup_context)
when :blocked then show_limit_reached()
end
```

One call does the whole loop: ask, run with the resolved model, report the real
cost, acknowledge what your application did.

### Why a block rather than a returned decision

Enforcement must not depend on you remembering to check anything. If `guard`
returned a decision for you to act on, forgetting the check once would mean a
blocked request reaches the provider anyway. With a block that is structurally
impossible: when the verdict is `:block`, the block is never yielded to.

### Why decide never raises

There is no failure a caller should branch on. A decision that times out or
errors is an *allow* with `degraded?` true, because MarginFuse being unreachable
must never become your outage. Transport failures go to `on_error`.

## Tell MarginFuse what a customer pays

Margin needs a revenue side. With Stripe connected it comes from there. Without
one, you declare your plans in MarginFuse and say which plan each customer is
on:

```ruby
result = mf.identify(
  customer_id: "user_8x2m91",
  plan: "pro", # the key of a plan you declared in Settings
  name: "Acme Studio",
  metadata: { "tier" => "legacy" } # labels segment policies can match on
)

warn "MarginFuse identify: #{result.error}" unless result.ok?
```

Safe to call on every sign-in: sending the plan the customer is already on
changes nothing. Sending a different one ends the current cycle and prorates
what accrued. `period_start` backdates the cycle for a customer who has been
paying since an earlier date; `clear_plan: true` takes them off plans.

This is the one call that does not fail open. `track` retries later and
`decide` allows, because both have a safe default; "I could not record what
this customer pays" has none, and a wrong plan is a wrong margin. So it reports
the failure to you instead of swallowing it. It still never raises.

`track`, `guard` and `decide` also accept a `plan`, so it can ride along with
usage rather than needing its own call. There it is a hint: a key that does not
resolve is ignored rather than failing your event.

## OpenRouter and other gateways

Gateways report the real cost of every call. Forward it and your figures are
exact instead of estimated.

```ruby
response = client.chat(model: "anthropic/claude-sonnet-4.5", messages: messages)

mf.track(
  customer_id: "cus_8x2m91",
  feature: "ai_chat",
  provider: "openrouter",
  model: "anthropic/claude-sonnet-4.5",
  **MarginFuse::OpenRouter.from(response["usage"])
)
```

Use the helper rather than mapping the fields yourself. OpenRouter's
`prompt_tokens` already includes cached reads and cache writes, which MarginFuse
prices separately, so passing it through directly charges every cached token
twice at the full input rate. The helper also formats the cost as a decimal
string, because `1.2e-07.to_s` produces exponent notation and the API rejects
that.

## Configuration

```ruby
MarginFuse.new(
  api_key: ENV.fetch("MARGINFUSE_KEY"),
  base_url: "https://api.marginfuse.com",  # your own deployment in dev
  timeout: 1.5,                            # decide budget before failing open
  on_error: ->(error, context) { Rails.logger.warn("marginfuse #{context}: #{error}") }
)
```

`on_error` is the only place transport failures surface. The SDK swallows them
so they cannot become your outage; without the hook they are silent.

### In Rails

The client is safe to share, so build one at boot:

```ruby
# config/initializers/marginfuse.rb
MARGINFUSE = MarginFuse.new(
  api_key: Rails.application.credentials.marginfuse_key,
  on_error: ->(error, context) { Rails.logger.warn("marginfuse #{context}: #{error}") }
)
```

## What it sends

Everything, and nothing else:

```
event_id  customer_id  feature  provider  model  requested_model
usage(input_tokens, output_tokens, cached_input_tokens,
      cache_creation_tokens, images, audio_seconds)
cost_usd  occurred_at  outcome  decision_id  retry_of_event_id  corrects_event_id
```

There is no field for message content anywhere in the wire types. The
[conformance suite](https://github.com/marginfuse/sdk-contract) checks this
against the bytes that actually leave the process, on every scenario.

## Conformance

This SDK is verified against
[marginfuse/sdk-contract](https://github.com/marginfuse/sdk-contract), the same
contract every MarginFuse SDK in every language is held to. It is a submodule
here, so the pinned commit records exactly which contract a release passed, and
`MarginFuse::CONTRACT_VERSION` reports it at runtime.

```bash
git clone --recurse-submodules https://github.com/marginfuse/marginfuse-ruby
cd marginfuse-ruby
bundle install
bundle exec rake test        # unit tests, plus the shared gateway vectors
npm --prefix contract/harness install
npm --prefix contract/harness run conformance ruby
```

## Links

- [MarginFuse](https://marginfuse.com), product and pricing
- [Documentation](https://marginfuse.com/docs)
- [API reference](https://api.marginfuse.com/openapi.json)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)

MIT, Pemira Labs.
