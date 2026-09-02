# frozen_string_literal: true

# Provides build, install and release. The rubygems/release-gem action runs
# `rake release`, which lives here rather than in this file.
require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "spec"
  t.libs << "lib"
  t.test_files = FileList["spec/**/*_test.rb"]
  t.warning = true
end

task default: :test
