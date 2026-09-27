# frozen_string_literal: true

return if RUBY_ENGINE == "truffleruby"
require_relative "../../setup"

class TestInternalAutoloads < Test
  def test_reservation_waits_during_concurrent_first_use
    output, error, status = ruby_isolated(<<~RUBY)
      require "farce"
      waiting = Farce.const_get(:Internal)::ReservationWaiting
      signal = Object.new
      def signal.wait(*) = true

      # Widen the interval between publishing the module and defining its methods.
      trace = TracePoint.new(:class) do |event|
        10_000.times { Thread.pass } if event.self.name == "Farce::Internal::LeaseWaiting"
      end
      trace.enable do
        8.times.map { Thread.new { waiting.wait(signal, 0, nil) } }.each(&:value)
      end
      puts "ok"
    RUBY

    assert_predicate status, :success?, error
    assert_equal "ok", output.strip
  end

  def test_thread_pool_and_scheduler_helpers_load_independently
    output, error, status = ruby_isolated(<<~'RUBY')
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
