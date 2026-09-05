# frozen_string_literal: true

require "bundler/setup"
require "simplecov-console"

SimpleCov.configure do
  merging true
  finalize_merge false

  formatters [
    SimpleCov::Formatter::HTMLFormatter.new(silent: true),
    SimpleCov::Formatter::JSONFormatter.new(silent: true),
    SimpleCov::Formatter::Console
  ]

  command_name "#{RUBY_ENGINE.capitalize.sub("ruby", "Ruby")} #{RUBY_ENGINE_VERSION}"
  coverage_dir ENV["COVERAGE_DIR"] || "coverage/#{RUBY_ENGINE}-#{RUBY_ENGINE_VERSION}"

  cover "lib/**/*.rb"
  skip  "lib/farce/_yard"
  skip  "lib/farce/version.rb"

  # somehow simplecov doesn't pick these up, so we'll skip them
  Dir.glob("lib/farce/engine/ruby/3.4/*.rb", base: __dir__) { skip it }
  skip "lib/farce/engine/ruby/containers.rb"
  skip "lib/farce/engine/ruby/shared/vault.rb" # ?

  source_in_json false
end

SimpleCov::Formatter::Console.missing_len  = 20
SimpleCov::Formatter::Console.max_rows     = 50
SimpleCov::Formatter::Console.show_covered = true
