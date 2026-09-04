# frozen_string_literal: true

require "rake/testtask"
require_relative "test_watchdog"

test_runner = Rake::TestTask.new("test:run") do |t|
  t.test_files = FileList["test/**/test_*.rb"]
end

desc "Run tests with an external process watchdog"
task :test do
  command, seed = TestWatchdog.test_command(test_runner)
  timeout = ENV.fetch("TEST_TIMEOUT", TestWatchdog::DEFAULT_TIMEOUT)
  shutdown_grace = ENV.fetch("TEST_SHUTDOWN_GRACE", TestWatchdog::DEFAULT_SHUTDOWN_GRACE)
  result = TestWatchdog.new(command, seed: seed, timeout: timeout, shutdown_grace: shutdown_grace).run
  exit result unless result.zero?
end

desc "Generate coverage report"
task "coverage:report" do
  ENV["COVERAGE_DIR"] = "coverage"
  require "simplecov"
  SimpleCov.collate Dir["coverage/*/.resultset.json"]
  puts "Full coverage reports:", "* #{SimpleCov.coverage_dir}/index.html", "* #{SimpleCov.coverage_dir}/coverage.json"
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError => e
  raise e unless e.path == "rubocop/rake_task"
end
