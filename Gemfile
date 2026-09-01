# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development do
  gem "minitest", "~> 5.25"
  gem "rake", "~> 13.2"
end

# Separate on purpose: rubocop's dependencies require a newer Ruby than this
# gem does, and a development tool must not decide which Rubies the library
# supports. CI lints on one version and tests on all of them.
group :lint do
  gem "rubocop", "~> 1.68"
end
