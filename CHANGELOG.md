# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0]

### Fixed

- A downgrade that crosses vendors is reported against the vendor that actually
  ran it. `guard()` already ran the model the server chose, but the usage event
  still named the requested provider, so the call was priced from the wrong
  catalog and the saving the downgrade exists to prove was computed against the
  wrong basis. An `allow` is unchanged, because the decision already defaults
  its provider to the requested one.
- A downgrade whose provider call then fails is acknowledged as
  `used_downgrade_model` rather than `proceeded_as_requested`. The cheaper model
  did run; what failed came after. Reporting otherwise told reconciliation the
  policy never applied, which skewed realized-savings attribution on the error
  path.

### Changed

- Pinned contract v2, whose new scenarios cover both corrections above and add
  a privacy check that hands the SDK content-bearing fields and scans the bytes
  that actually leave the process.

## [0.2.0]

### Added

- `identify`: tell MarginFuse who a customer is and which plan they are on.

  MarginFuse can now compute margin without a revenue source connected, from
  plans you declare in Settings and a plan assigned per customer. This call is
  how your application assigns that plan itself.

  ```ruby
  mf.identify(customer_id: "user_8x2m91", plan: "pro", name: "Acme Studio")
  ```

  `plan` is the key of a plan declared in MarginFuse, not a Stripe price id.
  Safe to call on every sign-in: sending the plan the customer is already on
  changes nothing. `period_start` backdates the cycle, `clear_plan` ends it.

  Unlike `track`, this one reports failure instead of failing quietly. A wrong
  plan is a wrong margin, and there is no safe default for "I could not record
  what this customer pays". Check `result.ok?`; `on_error` is called too. It
  still never raises into your code.

- `plan` on `track`, `guard` and `decide`, so a plan can ride along with usage
  rather than needing its own call. There it is a hint: a key that does not
  resolve is ignored rather than failing your event, because usage must never
  be lost to a plan note.

Both are additive. Existing code keeps working unchanged.

## [0.1.0]

First release. Ruby 3.2+, zero dependencies, standard library only.

### Added

- `MarginFuse::Client#track` reports an AI call that already happened. Returns
  immediately, sends on a background thread with retries, and never raises into
  application code.
- `MarginFuse::Client#decide` asks whether the next call should run. Fails open
  to `:allow` with `degraded?` true on any timeout or error.
- `MarginFuse::Client#guard` does the whole loop: ask, yield the decision, report
  the real cost, acknowledge what the application did.
- `MarginFuse::Client#flush`, for jobs and scripts that would otherwise exit
  before their last events are sent.
- `MarginFuse::OpenRouter.from` maps an OpenRouter usage object, including the
  gateway's own cost, so gateway figures are exact rather than estimated.
- `MarginFuse::CONTRACT_VERSION` reports the shared contract this build was
  verified against.

### Notes on the design

- **No bigdecimal.** The obvious way to format a nano-precision decimal is
  BigDecimal, and it stopped being a default gem in Ruby 3.4, so requiring it
  would quietly turn this into a package with a runtime dependency on a third of
  supported Rubies. `Kernel#format` is core and does the same job.
- **`guard` yields rather than returning a decision to act on.** Forgetting the
  check once would let a blocked request reach the provider.
- **`decide` never raises.** A failed decision is an allow with `degraded?` set.
- **Ruby 3.2, not 3.1.** The development toolchain does not install on 3.1, so
  the claim could not be verified, and 3.1 reached end of life in March 2025.
  Claiming a version CI cannot exercise is how an SDK ends up broken on it.
- Verified against
  [marginfuse/sdk-contract](https://github.com/marginfuse/sdk-contract): 16
  behavioral scenarios and 13 gateway vectors, the same ones the Node, Python,
  Go, Java and .NET SDKs pass.
