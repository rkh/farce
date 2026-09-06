# frozen_string_literal: true
require_relative "../../setup"
require "open3"

class TestInternalAutoloads < Test
  def test_thread_pool_and_scheduler_helpers_load_independently
    output, error, status = Open3.capture3(RbConfig.ruby,
      "-I#{File.expand_path("../../../lib", __dir__)}", "-e", <<~'RUBY')
        require "farce"
        internal = Farce.const_get(:Internal)
        paths = {
          SchedulerLifecycle: "scheduler_lifecycle",
          SchedulerIO: "scheduler_io",
          SelectScheduler: "select_scheduler",
          ThreadPool: "thread_pool"
        }
        paths.each do |name, file|
          abort "wrong helper path" unless internal.autoload?(name).end_with?("/internal/#{file}.rb")
        end
        pool = internal::ThreadPool.new(max_threads: 1)
        abort "pool result" unless pool.call { 42 } == 42
        pool.close
        abort "pool loaded a scheduler" unless internal.autoload?(:FiberScheduler)
        abort "pool loaded IO helpers" unless internal.autoload?(:SchedulerIO)
        abort "pool loaded select helpers" unless internal.autoload?(:SelectScheduler)
        select = internal::SelectScheduler
        abort "select scheduler name" unless select.name == "Farce::Internal::SelectScheduler"
        abort "IO helper missing" unless select.ancestors.include?(internal::SchedulerIO)
        abort "helpers loaded a scheduler" unless internal.autoload?(:FiberScheduler)
        lifecycle = internal::SchedulerLifecycle
        abort "lifecycle name" unless lifecycle.name == "Farce::Internal::SchedulerLifecycle"
        abort "lifecycle loaded a scheduler" unless internal.autoload?(:FiberScheduler)
        puts "ok"
      RUBY

    assert_predicate status, :success?, error
    assert_equal "ok", output.strip
  end
end
