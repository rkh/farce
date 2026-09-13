# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "setup"

class TestSubprocess < Test
  def test_captures_output_and_preserves_failure_status
    output, error, status = ruby_subprocess('puts "output"; warn "error"; exit 23')

    assert_equal "output\n", output
    assert_equal "error\n", error
    assert_equal 23, status.exitstatus
  end

  def test_passes_environment_and_load_paths_without_loading_farce
    output, error, status = ruby_subprocess(<<~RUBY, env: { "FARCE_SUBPROCESS_TEST" => "value" })
      abort "Farce loaded too early" if defined?(Farce::Clock)
      require "farce/config"
      puts ENV.fetch("FARCE_SUBPROCESS_TEST")
    RUBY

    assert_predicate status, :success?, error
    assert_equal "value\n", output
  end

  def test_drains_both_output_streams
    output, error, status = ruby_subprocess('$stdout.write("o" * 100_000); $stderr.write("e" * 100_000)')

    assert_predicate status, :success?
    assert_equal "o" * 100_000, output
    assert_equal "e" * 100_000, error
  end

  def test_environment_configures_the_default_timeout
    previous = ENV["TEST_SUBPROCESS_TIMEOUT"]
    ENV["TEST_SUBPROCESS_TIMEOUT"] = "0.05"

    error = assert_raises(Minitest::Assertion) do
      ruby_subprocess("sleep 30", coverage: false)
    end

    assert_includes error.message, "timed out after 0.05 seconds"
  ensure
    ENV["TEST_SUBPROCESS_TIMEOUT"] = previous
  end

  def test_timeout_terminates_the_child_and_reports_output
    previous = ENV["TEST_SUBPROCESS_TIMEOUT"]
    ENV["TEST_SUBPROCESS_TIMEOUT"] = "60"

    error = assert_raises(Minitest::Assertion) do
      ruby_subprocess('$stdout.sync = true; puts "started"; sleep 30', timeout: 0.05, coverage: false)
    end

    assert_includes error.message, "timed out after 0.05 seconds"
    assert_includes error.message, "stdout:"
    assert_includes error.message, "stderr:"
  ensure
    ENV["TEST_SUBPROCESS_TIMEOUT"] = previous
  end

  def test_coverage_can_be_disabled_for_a_child
    output, error, status = ruby_subprocess('puts defined?(SimpleCov) || "disabled"', coverage: false)

    assert_predicate status, :success?, error
    assert_equal "disabled\n", output
  end

  def test_coverage_bootstrap_uses_bundled_dependencies_without_rubyopt
    output, error, status = ruby_subprocess(<<~RUBY, env: { "COVERAGE" => "true", "RUBYOPT" => nil }, coverage: false)
      require "coverage_subprocess"
      abort "coverage is not running" unless Coverage.running?
      abort "Farce loaded too early" if defined?(Farce::Clock)
      require "json"
      puts JSON::VERSION
    RUBY

    assert_predicate status, :success?, error
    assert_empty error
    assert_equal "#{Gem.loaded_specs.fetch("json").version}\n", output
  end
end
