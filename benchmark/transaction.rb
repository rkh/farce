# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# Compare unchanged access paths before and after adding transaction support.
# Run this same file with -I pointing at each checkout's lib directory.
# Transaction setup is outside the measured loops, but loads and exercises the
# implementation so the comparison also covers programs that use transactions.
# Both checkouts exercise ordinary methods after optional transaction setup.
# This keeps setup effects on shared method caches comparable.
require "farce"
require "json"
require "objspace"

RubyVM::YJIT.enable if ENV.fetch("JIT", "true") != "false" && defined?(RubyVM::YJIT)

iterations = Integer(ENV.fetch("ITERATIONS", "1000000"))
samples = Integer(ENV.fetch("SAMPLES", "5"))
operations = {}
memory = {}

[Farce::Strict, Farce].each do |namespace|
  atom = namespace::Atom.new(1)
  map = namespace::Map.new({ key: 1 })
  vector = namespace::Vector.new([1])
  if Farce.respond_to?(:transaction)
    committed = Farce.transaction do |tx|
      tx[atom].value = 1
      tx[map][:key] = 1
      tx[vector][0] = 1
    end
    raise "setup transaction failed" unless committed
  end
  atom.store(1)
  map[:key] = 1
  vector[0] = 1
  prefix = namespace == Farce ? "mode" : "strict"
  operations["#{prefix}.atom.read"] = -> { atom.value }
  operations["#{prefix}.atom.store"] = -> { atom.store(1) }
  operations["#{prefix}.atom.cas"] = -> { atom.compare_and_set(1, 1) }
  operations["#{prefix}.map.read"] = -> { map[:key] }
  operations["#{prefix}.map.store"] = -> { map[:key] = 1 }
  operations["#{prefix}.map.update"] = -> { map.update(:key) { 1 } }
  operations["#{prefix}.vector.read"] = -> { vector[0] }
  operations["#{prefix}.vector.store"] = -> { vector[0] = 1 }
  [atom, map, vector].each do |object|
    storage = object.instance_variables.filter_map do |name|
      object.instance_variable_get(name) if %i[@atom @map @vector].include?(name)
    end.first
    memory[object.class.name] = [ObjectSpace.memsize_of(object), ObjectSpace.memsize_of(storage)]
  end
end
[Farce::Strict, Farce].each do |namespace|
  record = namespace::Molecule.define(:balance).new(1)
  set = namespace::Set.new([1])
  sorted = namespace::SortedSet.new([1])
  tree = namespace::TreeMap.new({ 1 => 1 })
  if Farce.respond_to?(:transaction)
    Farce.transaction do |tx|
      tx[record].balance = 1
      tx[set].add(1)
      tx[sorted].add(1)
      tx[tree][1] = 1
    end
  end
  record.balance = 1
  set.add(1)
  sorted.add(1)
  tree[1] = 1
  prefix = namespace == Farce ? "mode" : "strict"
  operations["#{prefix}.molecule.read"] = -> { record.balance }
  operations["#{prefix}.molecule.store"] = -> { record.balance = 1 }
  operations["#{prefix}.set.include"] = -> { set.include?(1) }
  operations["#{prefix}.set.add"] = -> { set.add(1) }
  operations["#{prefix}.sorted_set.include"] = -> { sorted.include?(1) }
  operations["#{prefix}.sorted_set.add"] = -> { sorted.add(1) }
  operations["#{prefix}.tree_map.read"] = -> { tree[1] }
  operations["#{prefix}.tree_map.store"] = -> { tree[1] = 1 }
  [record, set, sorted, tree].each do |object|
    storage = object.instance_variable_get(:@map) || record.balance_atom
    storage = storage.instance_variable_get(:@map) if storage.is_a?(Farce::Abstract::Map)
    memory[object.class.name || "#{namespace}::Molecule"] =
      [ObjectSpace.memsize_of(object), ObjectSpace.memsize_of(storage)]
  end
end
counter = Farce::Counter.new
flag = Farce::Flag.new
operations["counter.add"] = -> { counter.increment }
operations["flag.set"] = -> { flag.set }

results = {}
operations.each do |label, operation|
  iterations.times { operation.call }
  values = samples.times.map do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    iterations.times { operation.call }
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1e9 / iterations
  end
  results[label] = values.sort[values.size / 2]
end
puts JSON.generate(ruby: RUBY_DESCRIPTION, jit: ENV.fetch("JIT", "true"), nanoseconds: results, memory:)
