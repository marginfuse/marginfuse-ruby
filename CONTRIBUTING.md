# Contributing

## Getting set up

The conformance contract is a submodule, so clone with it:

```bash
git clone --recurse-submodules https://github.com/marginfuse/marginfuse-ruby
cd marginfuse-ruby
bundle install
bundle exec rake test
```

If you already cloned without it: `git submodule update --init --recursive`.

## Before you open a pull request

```bash
bundle exec rubocop
bundle exec rake test

npm --prefix contract/harness install
npm --prefix contract/harness run conformance ruby
```

CI runs all of it on Ruby 3.2, 3.3 and 3.4.

## Four rules worth knowing before you change behavior

**This SDK never raises into application code.** It sits in the request path of
somebody else's product. A transport error goes to the `on_error` hook and the
call proceeds. The one exception is `guard`, which propagates whatever your own
block raised, because your error handling owns provider failures.

**`guard` keeps its block.** Returning a decision for the caller to act on reads
fine and would be wrong: enforcement would depend on remembering a check, and
forgetting once means a blocked request reaches the provider.

**No runtime dependencies, and watch for the ones that used to be free.**
bigdecimal was a default gem until Ruby 3.4 and is not one now; requiring it
would add a dependency for every user on a current Ruby without anyone noticing.
Check `Gem::Specification.load("marginfuse.gemspec").dependencies` before
reaching for anything.

**Behavior is defined in the contract, not here.** The expectations live in
[marginfuse/sdk-contract](https://github.com/marginfuse/sdk-contract) as data,
and every MarginFuse SDK in every language reads the same files. If you are
changing what the SDK does rather than how it does it, the change starts with a
pull request there.

## Style

`rubocop` decides. Comments explain why, not what. No em dashes.
