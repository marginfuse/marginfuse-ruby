# frozen_string_literal: true

module MarginFuse
  VERSION = "0.2.0"

  # The version of the shared SDK contract this build was verified against.
  #
  # Gem versions differ per language, because each tracks its own breaking
  # changes: a rename in Python must not tell Ruby users something broke. What
  # makes the SDKs interchangeable is this, not the gem version. Two SDKs
  # reporting the same contract version have passed the same scenarios and the
  # same vectors.
  #
  # See github.com/marginfuse/sdk-contract
  CONTRACT_VERSION = 1
end
