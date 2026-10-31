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

require "bundler/setup"
require "benchmark/ips"
require "farce"

# Repeated cache hits on the same instances. Retain the value across GC.
key = String.new("key").freeze
value = Object.new.freeze
entries = { key => value }
hash = entries.dup
identity_hash = entries.dup.compare_by_identity
map = Farce::Strict::Map.new(entries)
identity_map = Farce::Strict::Map.new(entries, compare_keys_by_identity: true)
cache = Farce::Strict::WeakCache.new(entries)
identity_cache = Farce::Strict::WeakCache.new(entries, compare_by_identity: true)

Benchmark.ips do |x|
  x.config(time: 2, warmup: 1)
  x.report("Hash") { hash.fetch(key) { hash[key] = value } }
  x.report("Hash (identity)") { identity_hash.fetch(key) { identity_hash[key] = value } }
  x.report("Strict::Map") { map.store_if_absent(key) { value } }
  x.report("Strict::Map (identity)") { identity_map.store_if_absent(key) { value } }
  x.report("Strict::WeakCache") { cache.get(key) { value } }
  x.report("Strict::WeakCache (identity)") { identity_cache.get(key) { value } }
  x.compare!
end
