# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "setup"

class TestIsolatedRuby < Test
  def setup = require_subprocess_support

  def test_jruby_reuses_the_process
    return unless RUBY_ENGINE == "jruby"
    output, error, status = ruby_isolated("puts Process.pid", coverage: false)

    assert_predicate status, :success?, error
    assert_equal Process.pid, Integer(output)
  end

  def test_ruby_state_is_fresh_for_each_run
    2.times do
      output, error, status = ruby_isolated(<<~RUBY, coverage: false)
        abort "constant leaked" if defined?(IsolatedRubyMarker)
        abort "global leaked" if defined?($isolated_ruby_marker)
        abort "method leaked" if String.method_defined?(:isolated_ruby_marker)
        abort "feature leaked" if $LOADED_FEATURES.include?("isolated_ruby_marker.rb")
        abort "Farce loaded early" if defined?(Farce::Clock)
        IsolatedRubyMarker = true
        $isolated_ruby_marker = true
        class String
          def isolated_ruby_marker = true
        end
        $LOADED_FEATURES << "isolated_ruby_marker.rb"
        require "farce"
        puts Farce::Vector[1, 2].to_a.join(",")
      RUBY

      assert_predicate status, :success?, error
      assert_equal "1,2\n", output
    end

    refute Object.const_defined?(:IsolatedRubyMarker)
    refute String.method_defined?(:isolated_ruby_marker)
    refute_includes $LOADED_FEATURES, "isolated_ruby_marker.rb"
  end

  def test_environment_overrides_and_mutations_are_isolated
    name = "FARCE_ISOLATED_RUBY_TEST"
    previous = ENV[name]
    ENV[name] = "parent"
    output, error, status = ruby_isolated(<<~RUBY, env: { name => "child" }, coverage: false)
      puts ENV.fetch(#{name.inspect})
      ENV[#{name.inspect}] = "changed"
    RUBY

    assert_predicate status, :success?, error
    assert_equal "child\n", output
    assert_equal "parent", ENV[name]

    output, error, status = ruby_isolated("puts ENV.key?(#{name.inspect})", env: { name => nil }, coverage: false)

    assert_predicate status, :success?, error
    assert_equal "false\n", output
    assert_equal "parent", ENV[name]

    assert_equal "parent", JRuby.runtime.posix.getenv(name) if RUBY_ENGINE == "jruby"
  ensure
    ENV[name] = previous
  end

  def test_standard_streams_and_input_eof
    output, error, status = ruby_isolated(<<~'RUBY', coverage: false)
      abort "stdin is not empty" unless STDIN.read.empty?
      STDOUT.write("o" * 100_000)
      $stdout.write("é\x00")
      STDERR.write("e" * 100_000)
      warn "done"
    RUBY

    assert_predicate status, :success?
    assert_equal "#{"o" * 100_000}é\x00", output
    assert_equal "#{"e" * 100_000}done\n", error
  end

  def test_normal_results_are_not_exit_codes
    _, error, status = ruby_isolated("23", coverage: false)

    assert_predicate status, :success?, error
    assert_equal 0, status.exitstatus
  end

  def test_exit_status_and_at_exit_output
    output, error, status = ruby_isolated('at_exit { puts "finished" }; exit 23', coverage: false)

    assert_equal 23, status.exitstatus
    assert_instance_of Integer, status.exitstatus
    refute_predicate status, :success?
    assert_equal "finished\n", output
    assert_empty error
  end

  def test_at_exit_failure_is_reported
    _, error, status = ruby_isolated("at_exit { exit 7 }", coverage: false)

    assert_equal 7, status.exitstatus, error
    refute_predicate status, :success?
  end

  def test_exit_status_uses_the_process_status_byte_range
    [300, -1].each do |value|
      _, error, status = ruby_isolated("exit #{value}", coverage: false)

      assert_equal value & 0xff, status.exitstatus, error
      assert_instance_of Integer, status.exitstatus
    end
  end

  def test_exceptions_include_details_and_reach_at_exit
    output, error, status = ruby_isolated('at_exit { puts $!.class.name }; raise "isolated failure"', coverage: false)

    refute_predicate status, :success?
    assert_equal "RuntimeError\n", output
    assert_includes error, "isolated failure"
    assert_includes error, "-e:1"
  end

  def test_syntax_errors_are_reported
    _, error, status = ruby_isolated("def", coverage: false)

    refute_predicate status, :success?
    assert_includes error, "SyntaxError"
  end

  def test_at_exit_status_does_not_hide_the_original_exception
    _, error, status = ruby_isolated('at_exit { exit 7 }; raise "original failure"', coverage: false)

    assert_equal 7, status.exitstatus
    assert_includes error, "original failure"
  end

  def test_nested_test_failures_are_not_swallowed
    output, error, status = ruby_isolated(<<~RUBY)
      require "setup"
      class IsolatedFailure < Test
        def test_failure
          flunk "nested test failed"
        end
      end
    RUBY

    refute_predicate status, :success?, error
    assert_includes output, "nested test failed"
  end

  def test_timeout_includes_at_exit_and_does_not_poison_the_next_run
    ["sleep 30", "at_exit { sleep 30 }"].each do |source|
      error = assert_raises(Minitest::Assertion) { ruby_isolated(source, timeout: 2, coverage: false) }

      assert_includes error.message, "timed out after 2 seconds"
      assert_includes error.message, "stdout:"
      assert_includes error.message, "stderr:"
    end
    output, error, status = ruby_isolated('puts "next run"', coverage: false)

    assert_predicate status, :success?, error
    assert_equal "next run\n", output
  end

  def test_timeout_during_startup_does_not_poison_the_next_run
    error = assert_raises(Minitest::Assertion) { ruby_isolated("sleep 30", timeout: 0.001, coverage: false) }

    assert_includes error.message, "timed out after 0.001 seconds"

    _, error, status = ruby_isolated("nil", coverage: false)

    assert_predicate status, :success?, error
  end

  def test_teardown_stops_child_threads
    return unless RUBY_ENGINE == "jruby"
    name = "farce-isolated-ruby-#{Process.pid}-#{object_id}"
    _, error, status = ruby_isolated(<<~RUBY, coverage: false)
      ready = Queue.new
      Thread.new do
        Java::JavaLang::Thread.current_thread.name = #{name.inspect}
        ready << true
        sleep
      end
      ready.pop
    RUBY

    assert_predicate status, :success?, error
    refute(Java::JavaLang::Thread.all_stack_traces.key_set.any? { it.name == name && it.alive? })
  end

  def test_coverage_results_do_not_overwrite_another_runtime
    require "tmpdir"
    require "json"
    Dir.mktmpdir("farce-isolated-coverage") do |directory|
      names = 2.times.map do
        env = { "COVERAGE" => "true", "COVERAGE_DIR" => directory }
        output, error, status = ruby_isolated(<<~RUBY, env:, coverage: false)
          require "coverage_subprocess"
          require "farce"
          puts SimpleCov.command_name
        RUBY

        assert_predicate status, :success?, error
        output.strip
      end
      results = JSON.parse(File.read(File.join(directory, ".resultset.json")))

      assert_equal 2, names.uniq.size
      names.each { assert results.key?(it), "missing coverage for #{it}" }
    end
  end
end
