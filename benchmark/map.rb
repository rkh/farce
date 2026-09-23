# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# Run with ruby benchmark/map.rb. Requires benchmark-ips, concurrent-ruby,
# and ratomic (optional on unsupported Rubies). Override TIME, WARMUP, SIZE,
# FILTER, or JSON (an output filename prefix) through the environment.
require "bundler/setup"
require "benchmark/ips"
require "concurrent/map"
require "farce"

begin
  require "ratomic"
rescue LoadError => e
  warn "Skipping Ratomic::Map: #{e.message}"
end

class MutexHash
  def initialize
    @hash = {}
    @mutex = Mutex.new
  end

  def [](key) = @mutex.synchronize { @hash[key] }

  def []=(key, value)
    @mutex.synchronize { @hash[key] = value }
  end

  def size = @mutex.synchronize { @hash.size }
end

size = Integer(ENV.fetch("SIZE", "1024"))
time = Float(ENV.fetch("TIME", "3"))
warmup = Float(ENV.fetch("WARMUP", "1"))
filter = Regexp.new(ENV.fetch("FILTER", "."))
raise ArgumentError, "SIZE and TIME must be positive; WARMUP must be nonnegative" unless
  size.positive? && time.positive? && warmup >= 0

# Retain the frozen strings so weak maps keep their entries throughout the run.
# Shareable values avoid measuring value copying as part of map access.
entries = Ractor.make_shareable(Array.new(size) { |i| ["key-#{i}", "value-#{i}"] }.to_h)
key = entries.keys[size / 2]
value = "replacement"

factories = {
  "Hash"                    => -> { {} },
  "Hash + Mutex"            => -> { MutexHash.new },
  "Concurrent::Map"         => -> { Concurrent::Map.new },
  "ObjectSpace::WeakMap"    => -> { ObjectSpace::WeakMap.new },
  "ObjectSpace::WeakKeyMap" => -> { ObjectSpace::WeakKeyMap.new },
}
factories["Ratomic::Map"] = -> { Ratomic::Map.new } if defined?(Ratomic::Map)

[Farce, Farce::Strict, Farce::Unshared, Farce::Local, Farce::Unsafe].each do |namespace|
  %i[Map TreeMap LRUMap LFUMap WeakKeyMap WeakValueMap WeakMap LeaseMap].each do |name|
    next unless namespace.const_defined?(name, false)

    klass = namespace.const_get(name, false)
    label = klass.name
    factories[label] = case name
                       when :LRUMap, :LFUMap then -> { klass.new(max_size: size) }
                       when :LeaseMap then -> { klass.new { entries } }
                       else -> { klass.new }
                       end
  end
end
factories.select! { |name, _| filter.match?(name) }
abort "No matching implementations" if factories.empty?

puts RUBY_DESCRIPTION
puts "Farce #{Farce::VERSION}; benchmark-ips #{Benchmark::IPS::VERSION}"
puts "concurrent-ruby #{Gem.loaded_specs.fetch("concurrent-ruby").version}; " \
     "ratomic #{Gem.loaded_specs["ratomic"]&.version || "unavailable"}"
puts "#{size} entries; frozen String keys/values; defaults; one thread; GC enabled."
puts "Hot-key reads and repeated overwrites. One iteration is one map access."
puts "LeaseMap reads hold a checkout acquired before timing; writes are unowned."
puts "Hash/Unsafe lack synchronization. No contention, insertion, eviction, or copying measured."

%i[read write].each do |operation|
  puts "\n#{operation == :read ? "READ (hit)" : "WRITE (existing key)"}"
  maps = factories.to_h do |label, factory|
    map = factory.call
    entries.each { |entry_key, entry_value| map[entry_key] = entry_value }
    lease = map.is_a?(Farce::Abstract::LeaseMap)
    map.checkout(key) if lease
    raise "Incorrect setup: #{label}" unless map[key] == entries.fetch(key)
    map.checkin(key, entries.fetch(key)) if lease && operation == :write
    [lease && operation == :read ? "#{label} (checked out)" : label, map]
  end

  Benchmark.ips do |benchmark|
    benchmark.config(time:, warmup:)
    maps.each do |label, map|
      if operation == :read
        benchmark.report(label) { map[key] }
      else
        benchmark.report(label) { map[key] = value }
      end
    end
    benchmark.compare!
    benchmark.json!("#{ENV.fetch("JSON")}-#{operation}.json") if ENV["JSON"]
  end

  maps.each_value do |map|
    map.checkout(key) if map.is_a?(Farce::Abstract::LeaseMap) && (operation == :write)
    expected = operation == :read ? entries.fetch(key) : value
    raise "Incorrect result" unless map[key] == expected
    map.checkin(key, expected) if map.is_a?(Farce::Abstract::LeaseMap)
    raise "Map size changed" if map.respond_to?(:size) && map.size != size
  end
end
