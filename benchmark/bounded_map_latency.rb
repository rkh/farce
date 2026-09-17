# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# A thread-contention workload, separate from the low-overhead throughput harness.
require "farce"

size       = Integer(ENV.fetch("SIZE", "1024"))
workers    = Integer(ENV.fetch("THREADS", "4"))
operations = Integer(ENV.fetch("OPERATIONS", "25000"))
samples    = Integer(ENV.fetch("SAMPLES", "3"))
warmup     = Integer(ENV.fetch("WARMUP", "10000"))
filter     = Regexp.new(ENV.fetch("FILTER", "."))

raise ArgumentError, "positive size, threads, operations, samples and nonnegative warmup required" unless
  [size, workers, operations, samples].all?(&:positive?) && warmup >= 0

clock_id = Process.const_defined?(:CLOCK_MONOTONIC_RAW) ? Process::CLOCK_MONOTONIC_RAW : Process::CLOCK_MONOTONIC
clock    = -> { Process.clock_gettime(clock_id, :nanosecond) }

puts RUBY_DESCRIPTION
puts "Clock resolution: #{Process.clock_getres(clock_id, :nanosecond)} ns."
puts "#{workers} threads; #{operations} operations/thread; #{samples} samples; #{warmup} warmup operations."
puts "90% cache reads/loading and 10% distinct-key insertion/eviction; shared Integer keys and values."
puts "Latency includes clock-call overhead and scheduler delays. Thread startup and initial population excluded."
puts "Per-column medians across samples; GC time is process-wide when the runtime reports it."
puts "implementation,operations_per_second,p50_ns,p95_ns,p99_ns,gc_ms"

[Farce::Strict, Farce::Unshared].each do |namespace|
  %i[LRUMap LFUMap].each do |name|
    klass = namespace.const_get(name)
    next unless filter.match?(klass.name)

    results = Array.new(samples) do
      map = klass.new(max_size: size)
      size.times { |index| map[index] = index }
      warmup.times { |index| map.store_if_absent(index % size) { index } }
      ready = Thread::Queue.new
      start = Thread::Queue.new
      latencies = Array.new(workers) { Array.new(operations) }
      threads = Array.new(workers) do |worker|
        Thread.new do
          timings = latencies[worker]
          ready << true
          start.pop
          operations.times do |index|
            before = clock.call
            if (index % 10).zero?
              map[size + (worker * operations) + index] = index
            else
              key = index % size
              map.store_if_absent(key) { key }
            end
            timings[index] = clock.call - before
          end
        end
      end
      workers.times { ready.pop }
      GC.start
      gc_before = GC.stat[:time]
      before = clock.call
      workers.times { start << true }
      threads.each(&:value)
      elapsed = clock.call - before
      gc_after = GC.stat[:time]
      sorted = latencies.flatten.sort
      percentiles = [0.50, 0.95, 0.99].map { |fraction| sorted[((sorted.length - 1) * fraction).ceil] }
      gc_time = gc_before && gc_after ? gc_after - gc_before : nil
      [(workers * operations).fdiv(elapsed) * 1_000_000_000, *percentiles, gc_time]
    ensure
      threads&.each { it.kill.join if it.alive? }
    end
    medians = results.transpose.map do |values|
      present = values.compact.sort
      present.empty? ? "unavailable" : present[present.length / 2].round
    end
    puts [klass.name, *medians].join(",")
  end
end
