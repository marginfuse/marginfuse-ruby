# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0]

First release. Ruby 3.1+, zero dependencies, standard library only.

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
- Verified against
  [marginfuse/sdk-contract](https://github.com/marginfuse/sdk-contract): 16
  behavioral scenarios and 13 gateway vectors, the same ones the Node, Python,
  Go, Java and .NET SDKs pass.
