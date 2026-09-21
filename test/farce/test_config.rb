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

  module CustomLibrary
    class Scheduler
    end
  end

  def with_scheduler_env(value)
    previous = ENV["FARCE_FIBER_SCHEDULER"]
    ENV["FARCE_FIBER_SCHEDULER"] = value
    yield
  ensure
    ENV["FARCE_FIBER_SCHEDULER"] = previous
  end

  def test_builtin_choices
    config = Farce::Config.new
    { native: %i[native auto], jvm: %i[jvm auto], select: %i[select select],
      kqueue: %i[native kqueue], epoll: %i[native epoll], io_uring: %i[native io_uring],
      nio: %i[jvm nio] }.each do |choice, expected|
      [choice, choice.to_s].each do |value|
        config.fiber_scheduler = value

        assert_equal choice, config.fiber_scheduler
        assert_equal expected, [config.fiber_scheduler_implementation, config.io_backend]
        assert_nil config.fiber_scheduler_constructor
      end
    end
  end

  def test_auto_resets_implementation_and_backend
    [nil, :auto, "auto"].each do |value|
      config = Farce::Config.new { |c| c.fiber_scheduler = :nio }
      config.fiber_scheduler = value

      assert_equal :auto, config.fiber_scheduler
      assert_equal detected_implementation, config.fiber_scheduler_implementation
      assert_equal :auto, config.io_backend
    end
  end

  def test_environment_and_explicit_precedence
    with_scheduler_env("epoll") do
      assert_equal :epoll, Farce::Config.new.fiber_scheduler
    end
    with_scheduler_env("unknown") do
      assert_raises(ArgumentError) { Farce::Config.new }
      [nil, :auto, "auto", :select].each do |value|
        config = Farce::Config.new { |c| c.fiber_scheduler = value }

        assert_equal(value == :select ? :select : :auto, config.fiber_scheduler)
      end
    end
  end

  def test_classes_modules_and_names_construct_fresh_instances
    [CustomLibrary, CustomLibrary::Scheduler, "TestConfig::CustomLibrary",
     :"test_config::custom_library", "::TestConfig::CustomLibrary::Scheduler"].each do |value|
      config = Farce::Config.new { |c| c.fiber_scheduler = value }.freeze
      constructor = config.fiber_scheduler_constructor

      assert_same CustomLibrary::Scheduler, config.fiber_scheduler
      assert Farce::Ractor.shareable?(constructor)
      assert_instance_of CustomLibrary::Scheduler, constructor.call
      refute_same constructor.call, constructor.call
    end
    with_scheduler_env("TestConfig::CustomLibrary") do
      assert_same CustomLibrary::Scheduler, Farce::Config.new.fiber_scheduler
    end
  end

  def test_blocks_and_assigned_procs_are_shareable
    config = Farce::Config.new
    config.fiber_scheduler { TestConfig::CustomLibrary::Scheduler.new }

    assert Farce::Ractor.shareable?(config.fiber_scheduler)
    assert_instance_of CustomLibrary::Scheduler, config.fiber_scheduler_constructor.call
    config.fiber_scheduler = -> { TestConfig::CustomLibrary::Scheduler.new }
    config.freeze

    assert Farce::Ractor.shareable?(config.fiber_scheduler_constructor)
    assert_instance_of CustomLibrary::Scheduler, config.fiber_scheduler_constructor.call
  end

  def test_invalid_values_preserve_the_previous_choice
    invalid_module = Module.new
    invalid_module.const_set(:Scheduler, Object.new)
    inherited_module = Module.new { include CustomLibrary }
    config = Farce::Config.new { |c| c.fiber_scheduler = :select }
    [:unknown, "::", false, 1, Object.new, Module.new, invalid_module, inherited_module].each do |value|
      assert_raises(ArgumentError) { config.fiber_scheduler = value }
      assert_equal :select, config.fiber_scheduler
      assert_equal :select, config.io_backend
    end
  end

  def test_configured_constructors_run_in_workers_and_allow_overrides
    return if RUBY_ENGINE == "truffleruby"

    ["c.fiber_scheduler = CustomScheduler", "c.fiber_scheduler { CustomScheduler.new }"].each do |setting|
      %i[thread pool].product([false, true]).each do |executor, override|
        assert_configured_constructor(setting, executor, override)
      end
    end
  end

  def test_configured_worker_results_copy_across_ractors
    return if RUBY_ENGINE == "truffleruby"
    if RUBY_ENGINE == "ruby" && RUBY_VERSION.start_with?("4.0.") && Gem.win_platform? &&
        ENV["FARCE_RUN_QUARANTINED_TESTS"] != "1"
      skip "Windows CRuby 4.0 Vault copy regression runs in the non-blocking copy-transfer CI job"
    end

    assert_copied_worker_results
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
    with_scheduler_env(nil) do
      config = Farce::Config.new

      assert_equal detected_implementation, config.fiber_scheduler_implementation
      refute_predicate config, :frozen?
    end
  end

  def test_freeze_is_idempotent_and_prevents_changes
    config = Farce::Config.new { |c| c.fiber_scheduler = :select }

    assert_same config, config.freeze
    assert_same config, config.freeze
    assert_predicate config, :frozen?
    assert_raises(FrozenError) { config.fiber_scheduler = :native }
    assert_equal :select, config.fiber_scheduler_implementation
  end

  def test_frozen_config_is_shareable
    return unless RUBY_ENGINE == "ruby"
    config = Farce::Config.new { |c| c.fiber_scheduler = :select }.freeze

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
        c.fiber_scheduler = :select
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
    output, error, status = ruby_subprocess(<<~CODE, env: { "FARCE_FIBER_SCHEDULER" => "native" })
      require "farce/config"
      config = Farce.config do |c|
        c.fiber_scheduler = :select
      end
      abort "different config" unless Farce.config.equal?(config)
      abort "configuration frozen too early" if config.frozen?
      require "farce"
      abort "configuration replaced" unless Farce.config.equal?(config)
      abort "configuration lost" unless Farce.config.fiber_scheduler == :select
      puts "ok"
    CODE

    assert_predicate status, :success?, error
    assert_equal "ok", output.strip
  end

  private

  def assert_configured_constructor(setting, executor, override)
    output, error, status = ruby_subprocess(<<~CODE)
      require "farce"
      class CustomScheduler
        def self.new
          scheduler = Farce.const_get(:Internal)::FiberScheduler.new
          scheduler.instance_variable_set(:@constructor_name, name)
          scheduler.instance_variable_set(:@created_in_worker, !(Farce::Ractor.main? && Thread.current == Thread.main))
          scheduler
        end
      end
      class OverrideScheduler < CustomScheduler
      end
      Farce.config { |c| #{setting} }
      results = Farce::Queue.new
      constructor = proc { OverrideScheduler.new } if #{override}
      if #{executor == :thread}
        if #{override}
          scheduler = Farce::Scheduler.create(Thread, &constructor)
        else
          scheduler = Farce::Scheduler.new
          worker = scheduler.launch_thread
        end
        abort "custom scheduler not recognized" unless scheduler.wraps_external?
      else
        scheduler = Farce::Pool.new(max_size: 1, shrink_after: nil, &constructor)
      end
      scheduler.schedule(results) do |queue|
        current = Fiber.scheduler
        result = [current.instance_variable_get(:@constructor_name), current.instance_variable_get(:@created_in_worker)]
        queue << Farce::Ractor.make_shareable(result)
      end
      expected = #{override ? '"OverrideScheduler"' : '"CustomScheduler"'}
      abort "constructor ignored" unless results.pop(timeout: 2) == [expected, true]
      scheduler.close
      worker ? worker.join : (sleep 0.001 until scheduler.state == :closed)
      raise scheduler.error if scheduler.error
      puts "ok"
    CODE

    assert_predicate status, :success?, "#{setting}, #{executor}, override=#{override}: #{error}"
    assert_equal "ok", output.strip
  end

  def assert_copied_worker_results
    ["c.fiber_scheduler = CustomScheduler", "c.fiber_scheduler { CustomScheduler.new }"].each do |setting|
      output, error, status = ruby_subprocess(<<~CODE)
        require "farce"
        class CustomScheduler
          def self.new
            scheduler = Farce.const_get(:Internal)::FiberScheduler.new
            scheduler.instance_variable_set(:@constructor_name, name)
            scheduler.instance_variable_set(:@created_in_worker, !(Farce::Ractor.main? && Thread.current == Thread.main))
            scheduler
          end
        end
        class OverrideScheduler < CustomScheduler
        end
        Farce.config { |c| #{setting} }
        results = Farce::Queue.new
        scheduler = Farce::Scheduler.new
        abort "custom scheduler not recognized" unless scheduler.wraps_external?
        worker = scheduler.launch_thread
        scheduler.schedule(results) do |queue|
          current = Fiber.scheduler
          queue << [current.instance_variable_get(:@constructor_name), current.instance_variable_get(:@created_in_worker)]
        end
        abort "default ignored" unless results.pop(timeout: 2) == ["CustomScheduler", true]
        scheduler.close
        worker.join
        scheduler = Farce::Scheduler.create(Thread) { OverrideScheduler.new }
        scheduler.schedule(results) { |queue| queue << Fiber.scheduler.instance_variable_get(:@constructor_name) }
        abort "override ignored" unless results.pop(timeout: 2) == "OverrideScheduler"
        scheduler.close
        [false, true].each do |override|
          constructor = proc { OverrideScheduler.new } if override
          pool = Farce::Pool.new(max_size: 1, shrink_after: nil, &constructor)
          pool.schedule(results) do |queue|
            current = Fiber.scheduler
            queue << [current.instance_variable_get(:@constructor_name), current.instance_variable_get(:@created_in_worker)]
          end
          expected = override ? "OverrideScheduler" : "CustomScheduler"
          abort "pool constructor ignored" unless results.pop(timeout: 2) == [expected, true]
          pool.close
          sleep 0.001 until pool.state == :closed
          raise pool.error if pool.error
        end
        puts "ok"
      CODE

      assert_predicate status, :success?, error
      assert_equal "ok", output.strip
    end
  end
end
