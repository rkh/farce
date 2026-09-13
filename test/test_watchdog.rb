# frozen_string_literal: true

require "stringio"
require "tempfile"
require_relative "../rakelib/test_watchdog"
require_relative "setup"

class TestWatchdogTest < Minitest::Test
  include Helpers::Subprocess

  def test_success_and_failure_statuses_are_preserved
    assert_equal 0, run_watchdog("exit 0")
    assert_equal 23, run_watchdog("exit 23")
  end

  def test_timeout_has_a_distinct_status_and_reports_the_seed
    output = StringIO.new
    watchdog = TestWatchdog.new(
      ruby_command("sleep", coverage: false), seed: 12_345, timeout: 0.05, shutdown_grace: 0,
      diagnostics: false, output: output,
    )

    assert_equal TestWatchdog::TIMEOUT_EXIT_STATUS, watchdog.run
    assert_match(/seed 12345.*timed out.*rake test:run/m, output.string)
  end

  def test_seed_detection_accepts_long_minitest_forms
    assert_equal "123", TestWatchdog.seed_from(["--seed=123"])
    assert_equal "234", TestWatchdog.seed_from(["--seed", "234"])
    assert_nil TestWatchdog.seed_from(["--name", "seed"])
  end

  def test_seed_detection_accepts_short_minitest_forms
    assert_equal "345", TestWatchdog.seed_from(["-s345"])
    assert_equal "456", TestWatchdog.seed_from(["-s", "456"])
  end

  def test_timeout_terminates_descendant_processes
    skip "process-group assertion is POSIX-specific" if Gem.win_platform?

    Tempfile.create do |pid_file|
      source = 'sleep 30 & child=$!; printf "%s\n" "$child" > "$1"; wait'
      watchdog = TestWatchdog.new(
        ["/bin/sh", "-c", source, "test-watchdog", pid_file.path], seed: 1, timeout: 0.1,
        shutdown_grace: 0, diagnostics: false, output: StringIO.new,
      )

      watchdog.run
      descendant = Integer(File.read(pid_file.path))

      refute process_survives?(descendant)
    end
  end

  private

  def run_watchdog(source)
    command = Gem.win_platform? ? ruby_command(source, coverage: false) : ["/bin/sh", "-c", source]
    TestWatchdog.new(command, seed: 1, timeout: 2, diagnostics: false, output: StringIO.new).run
  end

  def process_survives?(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2

    loop do
      Process.kill(0, pid)
      return true if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    rescue Errno::ESRCH
      return false
    end
  end
end
