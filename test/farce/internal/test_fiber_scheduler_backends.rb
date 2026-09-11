# frozen_string_literal: true
return if RUBY_ENGINE == "truffleruby"
require_relative "../../setup"
require "open3"

module Farce
  module Internal
    class TestFiberSchedulerBackends < Test
      def test_implementation_loads_the_single_internal_scheduler
        implementations = RUBY_ENGINE == "ruby" ? %w[native select] : ["jvm"]
        implementations.each do |implementation|
          env = { "FARCE_FIBER_SCHEDULER_IMPLEMENTATION" => implementation, "FARCE_IO_BACKEND" => nil }
          output, error, status = Open3.capture3(env,
            RbConfig.ruby, "-I#{File.expand_path("../../../lib", __dir__)}", "-e", <<~RUBY)
              require "farce"
              module Farce
                module Internal
                  native_features = $LOADED_FEATURES.select do |feature|
                    feature.match?(%r{/engine/ruby/[0-9]+[.][0-9]+/(?:farce|containers|fiber_scheduler)[.](?:bundle|so)$})
                  end
                  if RUBY_ENGINE == "ruby" && native_features.map { File.basename(it, ".*") } != ["farce"]
                    abort "wrong native extensions loaded: \#{native_features.inspect}"
                  end
                  path = Internal.autoload?(:FiberScheduler)
                  unless path&.delete_suffix(".rb")&.end_with?("/engine/#{RUBY_ENGINE}/fiber_scheduler")
                    abort "wrong engine loader: \#{path.inspect}"
                  end
                  klass = FiberScheduler
                  abort "configuration is mutable" unless Farce.config.frozen?
                  s = klass.new
                  abort "extra public autoload" if Internal.const_defined?(:SelectFiberScheduler, false)
                  abort "scheduler name" unless klass.name == "Farce::Internal::FiberScheduler"
                  abort "extra scheduler class" unless klass.superclass == Object
                  abort "public scheduler remains" if Unsafe.const_defined?(:FiberScheduler, false)
                  abort "lifecycle missing" unless klass.ancestors.include?(SchedulerLifecycle)
                  abort "scheduler can freeze" if s.respond_to?(:freeze)
                  abort "scheduler shareable" if s.ractor_shareable?
                  Fiber.set_scheduler(s)
                  order = []
                  Fiber.schedule do
                    order << :before
                    s.kernel_sleep(0)
                    order << :after
                  end
                  abort "not immediate" unless order == [:before]
                  s.run
                  Fiber.set_scheduler(nil)
                  puts s.backend
                end
              end
            RUBY
          assert_predicate status, :success?, "#{implementation}: #{error}"
          assert_includes %w[select epoll io_uring kqueue nio], output.strip
        end
      end

      def test_programmatic_config_overrides_environment_and_freezes_on_use
        output, error, status = Open3.capture3({ "FARCE_FIBER_SCHEDULER_IMPLEMENTATION" => "native" },
          RbConfig.ruby, "-I#{File.expand_path("../../../lib", __dir__)}", "-e", <<~RUBY)
            require "farce/config"
            module Farce
              module Internal
                config = Farce.config do |c|
                  c.fiber_scheduler_implementation = RUBY_ENGINE == "ruby" ? :select : :jvm
                end
                require "farce"
                abort "configuration frozen too early" if config.frozen?
                scheduler = FiberScheduler.new
                expected = RUBY_ENGINE == "ruby" ? :select : :nio
                abort "backend ignored" unless scheduler.backend == expected
                abort "configuration not frozen" unless config.frozen?
                begin
                  Farce.config { |c| c.fiber_scheduler_implementation = :native }
                  abort "configuration changed after use"
                rescue FrozenError
                  # Expected once the backend has loaded.
                end
                Fiber.set_scheduler(scheduler)
                Fiber.set_scheduler(nil)
                puts "ok"
              end
            end
          RUBY

        assert_predicate status, :success?, error
        assert_equal "ok", output.strip
      end

      def test_unknown_implementation_fails_clearly
        _, error, status = Open3.capture3({ "FARCE_FIBER_SCHEDULER_IMPLEMENTATION" => "unknown" },
          RbConfig.ruby, "-I#{File.expand_path("../../../lib", __dir__)}", "-e", 'require "farce"')

        refute_predicate status, :success?
        assert_includes error, "unknown fiber scheduler implementation"
      end

      def test_incompatible_implementation_is_a_load_error
        implementations = RUBY_ENGINE == "ruby" ? ["jvm"] : %w[native select]
        implementations.each do |implementation|
          env = { "FARCE_FIBER_SCHEDULER_IMPLEMENTATION" => implementation, "FARCE_IO_BACKEND" => nil }
          output, error, status = Open3.capture3(env,
            RbConfig.ruby, "-I#{File.expand_path("../../../lib", __dir__)}", "-e", <<~RUBY)
              require "farce"
              module Farce
                module Internal
                  begin
                    FiberScheduler
                    abort "unexpected scheduler support"
                  rescue LoadError
                    puts "load error"
                  end
                end
              end
            RUBY

          assert_predicate status, :success?, "#{implementation}: #{error}"
          assert_equal "load error", output.strip
        end
      end

      def test_configured_backend_and_constructor_override
        implementation = RUBY_ENGINE == "ruby" ? "select" : "jvm"
        backend = RUBY_ENGINE == "ruby" ? "select" : "nio"
        [backend, "io_uring"].each do |configured|
          output, error, status = Open3.capture3({
            "FARCE_FIBER_SCHEDULER_IMPLEMENTATION" => implementation,
            "FARCE_IO_BACKEND"                     => configured,
          }, RbConfig.ruby, "-I#{File.expand_path("../../../lib", __dir__)}", "-e", <<~RUBY)
            require "farce"
            module Farce
              module Internal
                klass = FiberScheduler
                abort "config ignored" unless Farce.config.io_backend == :#{configured}
                if :#{configured} == :#{backend}
                  scheduler = klass.new
                  abort "driver ignored" unless scheduler.backend == :#{backend}
                  scheduler.close
                else
                  begin
                    klass.new
                    abort "incompatible driver accepted"
                  rescue ArgumentError
                    # Driver availability belongs to the selected implementation.
                  end
                end
                scheduler = klass.new(backend: :auto)
                abort "override ignored" unless scheduler.backend == :#{backend}
                scheduler.close
                puts "ok"
              end
            end
          RUBY

          assert_predicate status, :success?, error
          assert_equal "ok", output.strip
        end
      end

      def test_forced_unavailable_driver_does_not_silently_fall_back
        assert_raises(ArgumentError, SystemCallError) { FiberScheduler.new(backend: :unknown) }
      end
    end
  end
end
