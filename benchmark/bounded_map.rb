# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# Run with ruby -Ilib benchmark/bounded_map.rb. Adjust SIZES, OPERATIONS,
# SAMPLES, WARMUP, FILTER, WORKLOAD, and KEYS to select a reproducible workload.
# Hash and ordered Hash are unsynchronized reference points, not replacements
# for the thread-safe or Ractor-shareable implementations.
require "farce"
require "farce/engine/shared/portable_bounded_map"

class OrderedHashLRU
  def initialize(max_size:)
    @max_size = max_size
    @entries = {}
  end

  def [](key)
    return unless @entries.key?(key)
    value = @entries.delete(key)
    @entries[key] = value
  end

  def []=(key, value)
    @entries.delete(key)
    @entries.shift if @entries.size >= @max_size && @max_size.positive?
    @entries[key] = value if @max_size.positive?
    value
  end

  def prune(to:)
    removed = 0
    while @entries.size > to
      @entries.shift
      removed += 1
    end
    removed
  end

  def size = @entries.size
end

sizes = ENV.fetch("SIZES", "16,1024,65536").split(",").map { Integer(it) }
operations = Integer(ENV.fetch("OPERATIONS", "100000"))
samples = Integer(ENV.fetch("SAMPLES", "3"))
warmup = Integer(ENV.fetch("WARMUP", "10000"))
filter = Regexp.new(ENV.fetch("FILTER", "."))
workload_filter = Regexp.new(ENV.fetch("WORKLOAD", "."))
key_kind = ENV.fetch("KEYS", "integer")
raise ArgumentError, "KEYS must be integer, string, symbol, or array" unless
  %w[integer string symbol array].include?(key_kind)
raise ArgumentError, "positive sizes, operations, samples and nonnegative warmup required" unless
  sizes.all?(&:positive?) && operations.positive? && samples.positive? && warmup >= 0

implementations = {
  "Hash (lookup floor, unsynchronized)" => [->(_size) { {} }, false],
  "Ordered Hash LRU (unsynchronized)"   => [->(size) { OrderedHashLRU.new(max_size: size) }, true],
  "Farce::Strict::Map (unbounded)"      => [->(_size) { Farce::Strict::Map.new }, false],
}
[Farce, Farce::Strict, Farce::Unshared, Farce::Local, Farce::Unsafe, Farce.const_get(:Internal)].each do |namespace|
  %i[LRUMap LFUMap PortableLRUMap PortableLFUMap].each do |name|
    next unless namespace.const_defined?(name, false)
    klass = namespace.const_get(name, false)
    implementations[klass.name] = [->(size) { klass.new(max_size: size) }, true]
  end
end
# Isolate the cost of per-key construction/write coordination without changing
# production classes. These experimental wrappers retain backend structural locks.
if ENV["UNCOORDINATED"] == "1"
  %i[LRUMap LFUMap].each do |name|
    backend = Farce.const_get(:Internal).const_get(name)
    prototype = Class.new(Farce::Abstract::BoundedMap) do
      private

      def new_key_locks(**) = nil
      def with_key_lock(_key) = yield
    end
    prototype.define_method(:new_bounded_map) { |**options| backend.new(**options) }
    prototype.send(:private, :new_bounded_map)
    label = "Uncoordinated #{name} prototype (backend guard retained)"
    implementations[label] = [->(size) { prototype.new(max_size: size) }, true]
  end
end
implementations.select! { |name, _| filter.match?(name) }
abort "No matching implementations" if implementations.empty?

clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
allocation_counts_available = GC.stat.key?(:total_allocated_objects)
allocations = -> { GC.stat(:total_allocated_objects) if allocation_counts_available }
median = ->(values) { values.sort[values.length / 2] }
puts RUBY_DESCRIPTION
puts "Farce #{Farce::VERSION}; #{operations} operations; #{samples} samples; #{warmup} warmup operations"
puts "#{key_kind} keys and Integer values; median elapsed ns/op and allocated objects/op."
puts "Key construction and initial setup are excluded."
puts "Allocation counts are unavailable on runtimes that do not expose total_allocated_objects."
puts "Prune rows measure a complete refill-and-prune cycle, not one removed entry."
puts "size,implementation,workload,ns_per_operation,allocations_per_operation"

sizes.each do |size|
  keys = Array.new(size + operations) do |index|
    case key_kind
    when "integer" then index
    when "string" then "key-#{index}".freeze
    when "symbol" then :"key-#{index}"
    when "array" then [index, :cache].freeze
    end
  end
  workloads = {
    "cyclic hit"             => [operations, ->(map, i) { map[keys[i % size]] }],
    "hot hit"                => [operations, ->(map, _i) { map[keys[0]] }],
    "90 percent hot hits"    => [operations, ->(map, i) { map[keys[(i % 10).zero? ? i % size : 0]] }],
    "miss"                   => [operations, ->(map, i) { map[keys[size + i]] }],
    "existing write"         => [operations, ->(map, i) { map[keys[i % size]] = i }],
    "cache hit"              => [operations, lambda { |map, i|
      map.store_if_absent(keys[i % size]) do
        raise "unexpected cache miss"
      end
    }],
    "cache load and evict"   => [operations, ->(map, i) { map.store_if_absent(keys[size + i]) { i } }],
    "insert and evict"       => [operations, ->(map, i) { map[keys[size + i]] = i }],
    "refill and prune cycle" => [[operations / size, 1].max, lambda do |map, _i|
      size.times { |key| map[keys[key]] = key }
      map.prune(to: size / 2)
    end],
  }
  implementations.each do |name, (factory, bounded)|
    workloads.each do |workload, (count, operation)|
      next unless workload_filter.match?(workload)
      next if !bounded && ["insert and evict", "cache load and evict", "refill and prune cycle"].include?(workload)
      next if workload.start_with?("cache") && !factory.call(size).respond_to?(:store_if_absent)
      build = lambda do
        map = factory.call(size)
        size.times { |key| map[keys[key]] = key }
        raise "incorrect setup: #{name}" unless map.size == size && map[keys[0]].zero?
        map
      end
      warming = build.call
      [warmup, count].min.times { operation.call(warming, it) }
      elapsed = []
      allocated = []
      samples.times do
        map = build.call
        GC.start
        before_allocations = allocations.call
        started = clock.call
        count.times { operation.call(map, it) }
        elapsed << ((clock.call - started) * 1_000_000_000 / count)
        allocated << (allocations.call - before_allocations).fdiv(count) if before_allocations
        raise "capacity exceeded: #{name}" if bounded && map.size > size
      end
      allocation_result = allocated.empty? ? "unavailable" : format("%.4f", median.call(allocated))
      puts [size, name, workload, format("%.1f", median.call(elapsed)), allocation_result].join(",")
    end
  end
end
