# frozen_string_literal: true

$VERBOSE = false if RUBY_ENGINE == "jruby"
$stdout.sync = $stderr.sync = true if ENV["CI"]
require "bundler/setup" unless ENV["FARCE_STANDALONE_TESTS"] == "1"

if ENV["COVERAGE"] && ENV["COVERAGE"].downcase != "false"
  raise "Farce has been loaded before coverage tracking was enabled." if defined?(Farce::Clock)
  require "simplecov"
  SimpleCov.start unless Coverage.running?
end

require "farce"

$LOAD_PATH.unshift(__dir__)

require "minitest/autorun"
require "minitest/reporters"

unless Gem.win_platform?
  reporter = $stdout.tty? ? Minitest::Reporters::ProgressReporter : Minitest::Reporters::DefaultReporter
  Minitest::Reporters.use!(reporter.new)
end

module Helpers
  Internal = Farce.const_get(:Internal, false)
  include Internal::Autoloads["#{__dir__}/helpers"]

  # CRuby on Windows can leave a newly-created Ractor unscheduled when another
  # Ractor was recently created or terminated. A collection immediately before
  # spawning is enough to make the scheduler progress, while keeping the
  # workaround out of ordinary thread-only tests.
  module WindowsRactorStartBarrier
    def new(...)
      main = Ractor.current == Ractor.main
      GC.start if main
      super
    end
  end
end

if RUBY_ENGINE == "ruby" && Gem.win_platform?
  Ractor.singleton_class.prepend(Helpers::WindowsRactorStartBarrier)
end

class Test < Minitest::Test
  include Helpers
  include Helpers::IsolatedRuby
end

# Only stop shared schedulers that a test started.
Minitest.after_run do
  internal = Farce.const_get(:Internal)
  %i[ParallelScheduler MainScheduler].each do |name|
    next if internal.autoload?(name)
    scheduler = internal.const_get(name)
    next if scheduler.is_a?(Farce::ThreadScheduler)

    require "timeout"
    scheduler.close
    Timeout.timeout(5) { sleep 0.001 until scheduler.state == :closed }
  end
end
