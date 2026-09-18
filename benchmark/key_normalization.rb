# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "benchmark"
require "farce"

COUNT = Integer(ENV.fetch("COUNT", 200_000))
MAPS = Integer(ENV.fetch("MAPS", 2_000))
PASSES = Integer(ENV.fetch("PASSES", 20))
TYPE = ENV.fetch("TYPE", "Farce::Unshared::Map").split("::").reject(&:empty?).inject(Object) do |namespace, name|
  namespace.const_get(name, false)
end

def measure(label, operations = COUNT, &)
  GC.start
  allocations = GC.stat(:total_allocated_objects)
  elapsed = Benchmark.realtime(&)
  allocations = GC.stat(:total_allocated_objects) - allocations
  puts format(
    "%<label>-30s %<time>8.1f ns/op %<allocations>8d allocations",
    label:,
    time:        elapsed * 1_000_000_000 / operations,
    allocations:,
  )
end

ordinary = TYPE.new({ a: 1 })
normalized = TYPE.new({ a: 1 }, normalize_keys: :to_sym)

measure("ordinary read") { COUNT.times { ordinary[:a] } }
measure("normalized read") { COUNT.times { normalized["a"] } }
measure("ordinary store") { COUNT.times { ordinary[:a] = 1 } }
measure("normalized store") { COUNT.times { normalized["a"] = 1 } }

ordinary_maps = Array.new(MAPS) { TYPE.new({ a: 1 }) }
normalized_maps = Array.new(MAPS) { TYPE.new({ a: 1 }, normalize_keys: :to_sym) }
mixed_maps = ordinary_maps.zip(normalized_maps).flatten

operations = MAPS * PASSES
measure("many ordinary instances", operations) { PASSES.times { ordinary_maps.each { it[:a] } } }
measure("many normalized instances", operations) { PASSES.times { normalized_maps.each { it["a"] } } }
measure("mixed call site", operations) { (PASSES / 2).times { mixed_maps.each { it[:a] } } }

measure("construct ordinary", MAPS) { Array.new(MAPS) { TYPE.new } }
measure("construct normalized", MAPS) { Array.new(MAPS) { TYPE.new(normalize_keys: :to_sym) } }
