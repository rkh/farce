# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true
require_relative "../setup"

class TestConfig < Test
  def test_global_config_returns_and_yields_the_same_instance
    config = Farce.config
    yielded = nil

    assert_same(config, Farce.config { |value| yielded = value })
    assert_same config, yielded
  end

  def with_implementation_env(value)
    previous = ENV["FARCE_FIBER_SCHEDULER_IMPLEMENTATION"]
    ENV["FARCE_FIBER_SCHEDULER_IMPLEMENTATION"] = value
    yield
  ensure
    ENV["FARCE_FIBER_SCHEDULER_IMPLEMENTATION"] = previous
  end

  def with_backend_env(value)
    previous = ENV["FARCE_IO_BACKEND"]
    ENV["FARCE_IO_BACKEND"] = value
    yield
  ensure
    ENV["FARCE_IO_BACKEND"] = previous
  end

  def test_backend_defaults_to_auto
    with_backend_env(nil) do
      assert_equal :auto, Farce::Config.new.io_backend
    end
  end

  def test_backend_accepts_driver_names_and_detection_values
    config = Farce::Config.new
    %i[auto epoll kqueue io_uring select nio].each do |backend|
      [backend, backend.to_s].each do |value|
        config.io_backend = value

        assert_equal backend, config.io_backend
      end
    end
    [nil, "", :detect, "detect"].each do |value|
      config.io_backend = :nio
      config.io_backend = value

      assert_equal :auto, config.io_backend
    end
  end

  def test_backend_environment_and_programmatic_precedence
    with_backend_env("epoll") do
      assert_equal :epoll, Farce::Config.new.io_backend
    end
    with_backend_env("unknown") do
      assert_raises(ArgumentError) { Farce::Config.new }
      config = Farce::Config.new { |c| c.io_backend = :nio }

      assert_equal :nio, config.io_backend
    end
  end

  def test_invalid_backend_preserves_the_previous_value
    config = Farce::Config.new { |c| c.io_backend = :select }
    [:native, :jvm, :unknown, false, 1, Object.new].each do |value|
      error = assert_raises(ArgumentError) { config.io_backend = value }

      assert_includes error.message, "unknown IO backend"
      assert_equal :select, config.io_backend
    end
  end

  def test_backend_cannot_change_after_freeze
    config = Farce::Config.new { |c| c.io_backend = :nio }.freeze

    assert_raises(FrozenError) { config.io_backend = :auto }
    assert_equal :nio, config.io_backend
  end

  def with_thread_pool_env(main, other)
    names = %w[FARCE_MAIN_THREAD_POOL_SIZE FARCE_ADDITIONAL_THREAD_POOL_SIZE]
    previous = names.map { ENV[it] }
    names.zip([main, other]).each { |name, value| ENV[name] = value }
    yield
  ensure
    names.zip(previous).each { |name, value| ENV[name] = value }
  end

  def test_thread_pool_defaults_and_environment
    with_thread_pool_env(nil, nil) do
      config = Farce::Config.new

      assert_equal 4, config.main_thread_pool_size
      assert_equal 2, config.additional_thread_pool_size
    end
    with_thread_pool_env("7", "3") do
      config = Farce::Config.new

      assert_equal 7, config.main_thread_pool_size
      assert_equal 3, config.additional_thread_pool_size
    end
  end

  def test_thread_pool_sizes_validate_before_changing
    config = Farce::Config.new
    %i[main_thread_pool_size additional_thread_pool_size].each do |name|
      setter = :"#{name}="
      config.public_send(setter, "5")

      assert_equal 5, config.public_send(name)
      [0, -1, "0", "-1", "", "invalid", "2.5", 2.5, false, nil].each do |value|
        assert_raises(ArgumentError) { config.public_send(setter, value) }
        assert_equal 5, config.public_send(name)
      end
    end
  end

  def test_thread_pool_configuration_overrides_environment_and_freezes
    with_thread_pool_env("invalid", "invalid") do
      assert_raises(ArgumentError) { Farce::Config.new }
      config = Farce::Config.new do |c|
        c.main_thread_pool_size = 6
        c.additional_thread_pool_size = 3
      end.freeze

      assert_equal 6, config.main_thread_pool_size
      assert_equal 3, config.additional_thread_pool_size
      assert_raises(FrozenError) { config.main_thread_pool_size = 1 }
      assert_raises(FrozenError) { config.additional_thread_pool_size = 1 }
    end
    with_thread_pool_env("4", "invalid") do
      assert_raises(ArgumentError) { Farce::Config.new }
    end
  end

  def detected_implementation
    case RUBY_ENGINE
    when "ruby" then RUBY_PLATFORM.match?(/linux|darwin|bsd/) ? :native : :select
    when "jruby" then :jvm
    else :select
    end
  end

  def test_default_detects_the_runtime_implementation
    with_implementation_env(nil) do
      config = Farce::Config.new

      assert_equal detected_implementation, config.fiber_scheduler_implementation
      refute_predicate config, :frozen?
    end
  end

  def test_explicit_implementations_accept_symbols_and_strings
    config = Farce::Config.new
    %i[native select jvm].each do |implementation|
      [implementation, implementation.to_s].each do |value|
        config.fiber_scheduler_implementation = value

        assert_equal implementation, config.fiber_scheduler_implementation
      end
    end
  end

  def test_detection_values_reset_an_explicit_implementation
    config = Farce::Config.new
    [nil, "", :detect, "detect"].each do |value|
      config.fiber_scheduler_implementation = :jvm
      config.fiber_scheduler_implementation = value

      assert_equal detected_implementation, config.fiber_scheduler_implementation
    end
  end

  def test_environment_selects_the_implementation
    %w[native select jvm detect].each do |value|
      with_implementation_env(value) do
        expected = value == "detect" ? detected_implementation : value.to_sym

        assert_equal expected, Farce::Config.new.fiber_scheduler_implementation
      end
    end
  end

  def test_constructor_block_takes_precedence_over_environment
    with_implementation_env("unknown") do
      yielded = nil
      config = Farce::Config.new do |c|
        yielded = c
        c.fiber_scheduler_implementation = "select"
      end

      assert_same config, yielded
      assert_equal :select, config.fiber_scheduler_implementation
    end
  end

  def test_invalid_values_leave_the_previous_implementation_intact
    config = Farce::Config.new { |c| c.fiber_scheduler_implementation = :select }
    [:unknown, "unknown", :epoll, false, 1, Object.new].each do |value|
      error = assert_raises(ArgumentError) { config.fiber_scheduler_implementation = value }

      assert_includes error.message, "unknown fiber scheduler implementation"
      assert_equal :select, config.fiber_scheduler_implementation
    end
  end

  def test_invalid_environment_is_rejected
    with_implementation_env("unknown") do
      assert_raises(ArgumentError) { Farce::Config.new }
    end
  end

  def test_freeze_is_idempotent_and_prevents_changes
    config = Farce::Config.new { |c| c.fiber_scheduler_implementation = :select }

    assert_same config, config.freeze
    assert_same config, config.freeze
    assert_predicate config, :frozen?
    assert_raises(FrozenError) { config.fiber_scheduler_implementation = :native }
    assert_equal :select, config.fiber_scheduler_implementation
  end

  def test_frozen_config_is_shareable
    return unless RUBY_ENGINE == "ruby"
    config = Farce::Config.new { |c| c.fiber_scheduler_implementation = :select }.freeze

    assert Ractor.shareable?(config)
    task = Ractor.new(config, &:fiber_scheduler_implementation)

    assert_equal :select, task.respond_to?(:value) ? task.value : task.take
  end

  def test_config_remains_editable_after_requiring_farce
    output, error, status = ruby_subprocess(<<~CODE)
      require "farce"
      config = Farce.config
      abort "configuration frozen by require" if config.frozen?
      Farce.config do |c|
        c.fiber_scheduler_implementation = :select
        c.io_backend = :select
        c.main_thread_pool_size = 3
        c.additional_thread_pool_size = 1
      end
      abort "configuration replaced" unless Farce.config.equal?(config)
      abort "configuration frozen while configuring" if config.frozen?
      actual = [config.fiber_scheduler_implementation, config.io_backend,
                config.main_thread_pool_size, config.additional_thread_pool_size]
      abort "configuration changes lost" unless actual == [:select, :select, 3, 1]
      puts "ok"
    CODE

    assert_predicate status, :success?, error
    assert_equal "ok", output.strip
  end

  def test_config_can_be_loaded_and_configured_before_farce
    output, error, status = ruby_subprocess(<<~CODE, env: { "FARCE_FIBER_SCHEDULER_IMPLEMENTATION" => "native" })
      require "farce/config"
      config = Farce.config do |c|
        c.fiber_scheduler_implementation = :select
      end
      abort "different config" unless Farce.config.equal?(config)
      abort "configuration frozen too early" if config.frozen?
      require "farce"
      abort "configuration replaced" unless Farce.config.equal?(config)
      abort "configuration lost" unless Farce.config.fiber_scheduler_implementation == :select
      puts "ok"
    CODE

    assert_predicate status, :success?, error
    assert_equal "ok", output.strip
  end
end
