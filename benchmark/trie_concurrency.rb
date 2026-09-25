# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# ruby -Ilib benchmark/trie_concurrency.rb > concurrency.json
# COUNT=1000 WORKERS=1,4 CALLS=250000 ROUNDS=3 KINDS=Thread,Ractor
# All workers share one immutable matcher. Timing excludes worker startup.
require "bundler/setup"
require "json"
require "time"
require "farce"

module TrieConcurrencyBenchmark
  module_function

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def run
    count   = Integer(ENV.fetch("COUNT", "1000"))
    calls   = Integer(ENV.fetch("CALLS", "250000"))
    rounds  = Integer(ENV.fetch("ROUNDS", "3"))
    workers = ENV.fetch("WORKERS", "1,4").split(",").map { Integer(it) }
    kinds   = ENV.fetch("KINDS", "Thread,Ractor").split(",")
    raise ArgumentError, "positive COUNT, CALLS, ROUNDS, WORKERS required" unless
      [count, calls, rounds, *workers].all?(&:positive?)
    raise ArgumentError, "KINDS must contain Thread or Ractor" unless (kinds - %w[Thread Ractor]).empty?
    rows = []
    %i[static digits fallback].each do |workload|
      trie = Farce::Strict::Trie.build do |builder|
        count.times do |i|
          parts = case workload
                  when :static then ["/api/r#{i}/1234/edit"]
                  when :digits then ["/api/r#{i}/", /(?<id>\d+)/, "/edit"]
                  else ["/api/r#{i}/", /(?<id>\p{N}+)/, "/edit"]
                  end
          builder.add(parts, i)
        end
      end
      ids = (0...count).to_a.shuffle(random: Random.new(250925)).take([count, 256].min)
      queries = ids.map { |i| "/api/r#{i}/1234/edit".freeze }.freeze
      queries.each_with_index do |query, index|
        expected = workload == :static ? [ids[index], [], {}, ""] : [ids[index], ["1234"], { "id" => "1234" }, ""]
        raise "Incorrect setup" unless trie.match(query) == expected
      end
      kinds.each do |kind|
        worker_class = kind == "Thread" ? Thread : Farce::Ractor
        workers.each do |worker_count|
          samples = rounds.times.map do
            ready = Farce::Strict::Queue.new
            release = Farce::Strict::Queue.new
            GC.start
            tasks = worker_count.times.map do |offset|
              worker_class.new(trie, queries, calls, offset, ready, release) do |tree, inputs, iterations, start, ready_queue, release_queue|
                # Prime regexp/engine state before the measured phase.
                100.times { tree.match(inputs[start % inputs.length]) }
                ready_queue << true
                release_queue.pop
                checksum = 0
                index = 0
                while index < iterations
                  checksum += tree.match(inputs[(index + start) % inputs.length])[0]
                  index += 1
                end
                checksum
              end
            end
            worker_count.times { ready.pop }
            started = clock
            worker_count.times { release << true }
            sums = tasks.map(&:value)
            elapsed = clock - started
            expected = worker_count.times.map do |offset|
              cycles, rest = calls.divmod(ids.length)
              (ids.sum * cycles) + rest.times.sum { |i| ids[(i + offset) % ids.length] }
            end
            raise "Incorrect concurrent results: #{sums.inspect} != #{expected.inspect}" unless sums == expected
            calls * worker_count / elapsed
          end
          sorted = samples.sort
          median = sorted.length.odd? ? sorted[sorted.length / 2] : sorted[(sorted.length / 2) - 1, 2].sum / 2.0
          record = { workload: workload, workers: worker_count, kind: kind, samples_ips: samples, median_ips: median }
          rows << record
          warn format("%-8s %-8s %d workers: %.0f calls/s", workload, kind, worker_count, median)
        end
      end
    end
    { metadata: { ruby: RUBY_DESCRIPTION, timestamp: Time.now.iso8601, yjit: defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?,
      count: count, calls_per_worker: calls, rounds: rounds, seed: 250925,
      native_ractors: Farce::Ractor.builtin?,
      scope: "Shared immutable matcher, complete results, GC enabled. Workers ready and primed before timing. Timed phase includes barrier release and result collection. Ractors are polyfilled on non-CRuby." }, results: rows }
  end
end

puts JSON.pretty_generate(TrieConcurrencyBenchmark.run)
