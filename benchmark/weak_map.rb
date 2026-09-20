# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "benchmark"
require "json"
require "farce"

count = Integer(ENV.fetch("COUNT", 100_000))
rounds = Integer(ENV.fetch("ROUNDS", 7))
types = [Farce::Strict::Map, Farce::Strict::WeakKeyMap, Farce::Strict::WeakValueMap, Farce::Strict::WeakMap]
results = { ruby: RUBY_DESCRIPTION, count:, rounds:, samples: {} }
types.each do |type|
  key = "key"
  map = type.new({ key => 1 })
  workloads = {
    read:   -> { count.times { map[key] } },
    write:  -> { count.times { map[key] = 1 } },
    hit:    -> { count.times { map.store_if_absent(key) { 1 } } },
    miss:   lambda do
      count.times do
        map.delete(key)
        map.store_if_absent(key) { 1 }
      end
    end,
    update: -> { count.times { map.update(key) { 1 } } },
    cas:    -> { count.times { map.compare_and_set(key, 1, 1) } },
  }
  workloads.clear if ENV["CONTENDED"] == "1"
  workloads.each do |name, work|
    work.call
    results[:samples]["#{type.name}/#{name}"] = Array.new(rounds) do
      GC.start
      allocated = GC.stat(:total_allocated_objects)
      elapsed = Benchmark.realtime(&work)
      { ns: elapsed * 1_000_000_000 / count, allocations: GC.stat(:total_allocated_objects) - allocated }
    end
  end
  next unless ENV["CONTENDED"] == "1"

  workers = Integer(ENV.fetch("WORKERS", 4))
  iterations = Integer(ENV.fetch("ITERATIONS", 100))
  delay = Float(ENV.fetch("DELAY", 0.001))
  results[:workers] = workers
  results[:iterations] = iterations
  results[:delay] = delay
  %i[shared_key separate_keys].each do |workload|
    results[:samples]["#{type.name}/#{workload}"] = Array.new(rounds) do
      started = Queue.new
      release = Queue.new
      threads = Array.new(workers) do |worker|
        Thread.new do
          started << true
          release.pop
          target = workload == :shared_key ? 0 : worker
          iterations.times do
            map.update(target) do
              sleep(delay)
              1
            end
          end
        end
      end
      workers.times { started.pop }
      Benchmark.realtime do
        workers.times { release << true }
        threads.each(&:value)
      end
    end
  end
end
puts JSON.pretty_generate(results)
