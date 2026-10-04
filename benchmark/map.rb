# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

if RUBY_ENGINE == "ruby"
  case ENV["JIT"].to_s.downcase
  when "", "yjit" then RubyVM::YJIT.enable
  when "zjit"     then RubyVM::ZJIT.enable
  when "false" # no-op
  else abort "Unknown JIT: #{ENV["JIT"].inspect}"
  end
end

# Run with ruby benchmark/map.rb. Requires benchmark-ips, concurrent-ruby, and ActiveSupport.
# Ratomic, ractor-sharing, and ractor_safe are optional on unsupported Rubies. Override TIME,
# WARMUP, SIZE, FILTER, or JSON (an output filename prefix) through the environment.
require "bundler/setup"
require "benchmark/ips"
require "concurrent/hash"
require "concurrent/map"
require "active_support/hash_with_indifferent_access"
require "farce"

begin
  require "ratomic"
rescue LoadError => e
  warn "Skipping Ratomic::Map: #{e.message}"
end

begin
  require "ractor/sharing"
rescue LoadError => e
  warn "Skipping ractor-sharing hashes: #{e.message}"
end

begin
  require "ractor_safe"
rescue LoadError => e
  warn "Skipping RactorSafe::HashMap: #{e.message}"
end

class MutexHash
  def initialize(hash = {})
    @hash  = hash
    @mutex = Mutex.new
  end

  def [](key) = @mutex.synchronize { @hash[key] }

  def []=(key, value)
    @mutex.synchronize { @hash[key] = value }
  end

  def size = @mutex.synchronize { @hash.size }
end

size   = Integer(ENV.fetch("SIZE", "1024"))
time   = Float(ENV.fetch("TIME", "3"))
warmup = Float(ENV.fetch("WARMUP", "1"))
filter = Regexp.new(ENV.fetch("FILTER", "."))
raise ArgumentError, "SIZE and TIME must be positive; WARMUP must be nonnegative" unless
  size.positive? && time.positive? && warmup >= 0

# Retain the frozen strings so weak maps keep their entries throughout the run.
# Shareable values avoid measuring value copying as part of map access.
entries = begin
  values = Array.new(size) { |i| ["key-#{i}".freeze, "value-#{i}".freeze] }.to_h.freeze
  defined?(Ractor) && Ractor.respond_to?(:make_shareable) ? Ractor.make_shareable(values) : values
end
key = entries.keys[size / 2]
value = "replacement"

factories = {
  "Hash"                                     => -> { {} },
  "Hash + Mutex"                             => -> { MutexHash.new },
  "Concurrent::Hash"                         => -> { Concurrent::Hash.new },
  "Concurrent::Map"                          => -> { Concurrent::Map.new },
  "ActiveSupport::HashWithIndifferentAccess" => -> { MutexHash.new(ActiveSupport::HashWithIndifferentAccess.new) },
}
factories["ObjectSpace::WeakMap"] = -> { ObjectSpace::WeakMap.new } if ObjectSpace.const_defined?(:WeakMap, false)
if ObjectSpace.const_defined?(:WeakKeyMap, false)
  factories["ObjectSpace::WeakKeyMap"] = -> { ObjectSpace::WeakKeyMap.new }
end
factories["Ratomic::Map"] = -> { Ratomic::Map.new } if defined?(Ratomic::Map)
factories["RactorSafe::HashMap"] = -> { RactorSafe::HashMap.new } if defined?(RactorSafe::HashMap)
if defined?(Ractor::LockHash)
  factories["Ractor::LockHash"]    = -> { Ractor::LockHash.new }
  factories["Ractor::KeyLockHash"] = -> { Ractor::KeyLockHash.new }
  factories["Ractor::ActorHash"]   = -> { Ractor::ActorHash.new }
end

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
puts "ractor-sharing #{Gem.loaded_specs["ractor-sharing"]&.version || "unavailable"}"
puts "ractor_safe #{Gem.loaded_specs["ractor_safe"]&.version || "unavailable"}"
puts "#{size} entries; frozen String keys/values; defaults; one thread; GC enabled."
puts "Hot-key reads and repeated overwrites. One iteration is one map access."
puts "LeaseMap reads hold a checkout acquired before timing; writes are unowned."
puts "ActorHash writes use synchronous dispatch so each iteration observes a completed write."
puts "Hash/Unsafe lack synchronization. No contention, insertion, eviction, or copying measured."

%i[read write].each do |operation|
  puts "\n#{operation == :read ? "READ (hit)" : "WRITE (existing key)"}"
  maps = factories.to_h do |label, factory|
    map = factory.call
    if label == "Ractor::LockHash"
      map.synchronize { |target| entries.each { |entry_key, entry_value| target[entry_key] = entry_value } }
    elsif label == "Ractor::ActorHash"
      entries.each { |entry_key, entry_value| map.set(entry_key, entry_value) }
    else
      entries.each { |entry_key, entry_value| map[entry_key] = entry_value }
    end
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
      elsif label == "Ractor::LockHash"
        benchmark.report(label) { map.synchronize { |target| target[key] = value } }
      elsif label == "Ractor::ActorHash"
        benchmark.report(label) { map.sync_send(:set, key, value) }
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
    actual_size = map.respond_to?(:size) ? map.size : map.to_h.size if map.respond_to?(:size) || map.respond_to?(:to_h)
    raise "Map size changed" if actual_size && actual_size != size
  end
end
