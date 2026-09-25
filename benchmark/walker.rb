# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce"
require "benchmark"
require "json"

width = Integer(ENV.fetch("WIDTH", 1000))
iterations = Integer(ENV.fetch("ITERATIONS", 10))
samples = Integer(ENV.fetch("SAMPLES", 3))
tree = Array.new(width) { |i| [i, "leaf#{i}".freeze].freeze }.freeze
shared = [1, "shared".freeze].freeze
dag = Array.new(width, shared).freeze
cycle = []
cycle.push(cycle, 1)
cycle.freeze

jobs = {
  scan: -> { Farce::Walker.each(tree) {} },
  unchanged: -> { Farce::Walker.modify(tree) { |_, walker| walker.traverse } },
  copy_unchanged: -> { Farce::Walker.modify(tree, copy: true) { |_, walker| walker.traverse } },
  sparse_change: -> {
    Farce::Walker.modify(tree, copy: true) { |value, walker| value.equal?(width / 2) ? -1 : walker.traverse }
  },
  all_changed: -> {
    Farce::Walker.modify(tree, copy: true) { |value, walker| Integer === value ? value + 1 : walker.traverse }
  },
  shared_graph: -> {
    Farce::Walker.modify(dag, copy: true) { |value, walker| Integer === value ? value + 1 : walker.traverse }
  },
  cycle: -> {
    Farce::Walker.modify(cycle, copy: true) { |value, walker| Integer === value ? value + 1 : walker.traverse }
  },
  cold_dedup: -> { Farce::Deduper.new.dedup(tree, copy: true) }
}

results = jobs.to_h do |name, run|
  3.times { run.call }
  measurements = Array.new(samples) do
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    seconds = Benchmark.realtime { iterations.times { run.call } }
    { seconds:, allocations_per_walk: (GC.stat(:total_allocated_objects) - allocated).fdiv(iterations) }
  end
  [name, measurements]
end
puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, width:, iterations:, samples:, results:)
