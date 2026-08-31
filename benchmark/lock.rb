# frozen_string_literal: true

# Run with: bundle exec ruby benchmark/lock.rb
# Tune with BENCHMARK_TIME, BENCHMARK_WARMUP, THREADS, and CONTENDED_ITERATIONS.

require "bundler/setup"
require "benchmark/ips"
require "farce"

module LockBenchmark
  module_function

  def positive_integer(name, default)
    value = Integer(ENV.fetch(name, default), 10)
    raise ArgumentError, "#{name} must be positive" unless value.positive?

    value
  end

  def positive_float(name, default)
    value = Float(ENV.fetch(name, default))
    raise ArgumentError, "#{name} must be finite and positive" unless value.finite? && value.positive?

    value
  end

  def contended(lock_class, thread_count, iterations)
    lock = lock_class.new
    value = 0
    threads = thread_count.times.map do
      Thread.new do
        iterations.times do
          lock.synchronize do
            current = value
            Thread.pass
            value = current + 1
          end
        end
      end
    end
    threads.each(&:join)

    expected = thread_count * iterations
    raise "lost updates: expected #{expected}, got #{value}" unless value == expected
  end
end

benchmark_time = LockBenchmark.positive_float("BENCHMARK_TIME", "5")
benchmark_warmup = LockBenchmark.positive_float("BENCHMARK_WARMUP", "2")
contended_iterations = LockBenchmark.positive_integer("CONTENDED_ITERATIONS", "250")
thread_count = LockBenchmark.positive_integer("THREADS", "4")
implementations = { "Mutex" => Mutex, "Farce::Lock" => Farce::Lock }.freeze
locks = implementations.transform_values(&:new)

if Farce::Lock.equal?(Mutex)
  puts "Farce::Lock aliases Mutex on #{RUBY_ENGINE}; both labels use the same implementation."
  puts
end

puts "Uncontended (one synchronization per iteration)"
Benchmark.ips do |benchmark|
  benchmark.config(time: benchmark_time, warmup: benchmark_warmup)
  locks.each do |name, lock|
    benchmark.report(name) { lock.synchronize { nil } }
  end
  benchmark.compare!
end

batch_size = thread_count * contended_iterations
puts
puts format(
  "Contended (%<batch>d synchronizations per iteration: " \
  "%<threads>d threads × %<iterations>d, with Thread.pass inside the lock)",
  batch:      batch_size,
  threads:    thread_count,
  iterations: contended_iterations,
)
Benchmark.ips do |benchmark|
  benchmark.config(time: benchmark_time, warmup: benchmark_warmup)
  implementations.each do |name, lock_class|
    benchmark.report(name) do
      LockBenchmark.contended(lock_class, thread_count, contended_iterations)
    end
  end
  benchmark.compare!
end
