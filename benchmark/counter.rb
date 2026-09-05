# frozen_string_literal: true

require "bundler/setup"
require "benchmark"
require "benchmark/ips"
require "farce"
require "fileutils"

counter_classes  = [Farce::Counter]
thread_classes   = [Farce::Counter]
ractor_classes   = [Farce::Counter]

begin
  require "concurrent"
  if defined?(Concurrent::CAtomicFixnum)
    counter_classes << Concurrent::CAtomicFixnum
    thread_classes  << Concurrent::CAtomicFixnum
  end
  if defined?(Concurrent::JavaAtomicFixnum)
    counter_classes << Concurrent::JavaAtomicFixnum
    thread_classes  << Concurrent::JavaAtomicFixnum
  end
  counter_classes << Concurrent::MutexAtomicFixnum
  thread_classes  << Concurrent::MutexAtomicFixnum
rescue LoadError => e
  warn "#{e.class}: #{e.message}"
end

begin
  require "ratomic"
  counter_classes << Ratomic::Counter
  thread_classes  << Ratomic::Counter
  ractor_classes  << Ratomic::Counter
rescue LoadError => e
  warn "#{e.class}: #{e.message}"
end

benchmark_time   = Float(ENV.fetch("BENCHMARK_TIME",   2))
benchmark_warmup = Float(ENV.fetch("BENCHMARK_WARMUP", 1))

# Each sample must perform exactly `times` operations. Comparing a persistent
# counter to `times` makes later samples skip their work. Keep dispatch outside
# these loops so the benchmark measures direct calls to the counter methods.
workloads = {
  increment: lambda do |counter, times|
    index = 0
    while index < times
      counter.increment(1)
      index += 1
    end
  end,
  decrement: lambda do |counter, times|
    index = 0
    while index < times
      counter.decrement(1)
      index += 1
    end
  end,
  value:     lambda do |counter, times|
    index = 0
    while index < times
      counter.value
      index += 1
    end
  end,
}

workloads.each do |operation, workload|
  puts "", "==== Single-threaded #{operation} ===="
  Benchmark.ips do |x|
    x.config(time: benchmark_time, warmup: benchmark_warmup)
    counter_classes.each do |counter_class|
      counter = counter_class.new
      x.report("#{counter_class.name}##{operation}") { |times| workload.call(counter, times) }
    end
    x.compare!
  end
end

return unless ENV["BENCHMARK_MULTITHREADED"]

worker_count = 4
increments   = Integer(ENV.fetch("BENCHMARK_INCREMENTS", 500_000))
raise ArgumentError, "BENCHMARK_INCREMENTS must be positive" unless increments.positive?

thread_types = { Thread => thread_classes }
thread_types[Ractor] = ractor_classes if defined?(Ractor)

thread_types.each do |worker_class, counter_classes|
  puts "", "==== #{worker_count} #{worker_class.name}s, #{increments} increments each (includes startup) ===="
  Benchmark.bmbm do |x|
    counter_classes.each do |counter_class|
      x.report(counter_class.name) do
        counter = counter_class.new
        workers = worker_count.times.map do
          worker_class.new(counter, increments) do |shared, count|
            index = 0
            while index < count
              shared.increment(1)
              index += 1
            end
            nil
          end
        end
        workers.each { it.respond_to?(:value) ? it.value : it.take }
        expected = worker_count * increments
        raise "lost increments: expected #{expected}, got #{counter.value}" unless counter.value == expected
      end
    end
  end
end
