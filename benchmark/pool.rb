# frozen_string_literal: true

require "bundler/setup"
require "benchmark"
require "benchmark/ips"
require "farce"

benchmark_time = Float(ENV.fetch("TIME", "3"))
warmup_time = Float(ENV.fetch("WARMUP", "1"))
completion = Farce::Queue.new(capacity: nil, mode: :raise)

scheduler = Farce::Scheduler.create(Ractor, capacity: nil)
single_pool = Farce::Pool.new(max_size: 1, max_inflight: nil, capacity: nil, shrink_after: nil)
fixed_pool = Farce::Pool.new(min_size: 4, max_size: 4, max_inflight: nil, capacity: nil, shrink_after: nil)

executors = {
  "Scheduler"   => scheduler,
  "Pool size 1" => single_pool,
  "Pool size 4" => fixed_pool,
}

Benchmark.ips do |x|
  x.config(time: benchmark_time, warmup: warmup_time)
  executors.each do |name, executor|
    x.report(name) do |times|
      times.times do
        executor.schedule(completion, mode: :raise, auto_local: false) { |queue| queue << true }
      end
      times.times { completion.pop }
    end
  end
  x.compare!
end

executors.each_value(&:close)
[scheduler, single_pool, fixed_pool].each do |executor|
  Thread.pass until executor.state == :closed
end

puts "", "Queue latency scale-up"
task_count = Integer(ENV.fetch("TASKS", "12"))
task_iterations = Integer(ENV.fetch("TASK_ITERATIONS", "200000"))

{
  "fixed 1"   => -> { Farce::Pool.new(max_size: 1, max_inflight: 1, shrink_after: nil) },
  "elastic 4" => -> { Farce::Pool.new(max_size: 4, max_inflight: 1, grow_after: 0.001, shrink_after: nil) },
  "fixed 4"   => -> { Farce::Pool.new(min_size: 4, max_size: 4, max_inflight: 1, shrink_after: nil) },
}.each do |name, build|
  pool = build.call
  elapsed = Benchmark.realtime do
    task_count.times do
      pool.schedule(completion, task_iterations, mode: :raise) do |queue, iterations|
        value = 0
        iterations.times { value += 1 }
        queue << true
      end
    end
    task_count.times { completion.pop }
  end
  puts format("%<name>-10s %<elapsed>.4fs", name:, elapsed:)
ensure
  if pool
    pool.close
    sleep 0.001 until pool.state == :closed
  end
end
