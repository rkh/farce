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

class IVar
  def initialize = @ivar = 42
  def value = @ivar
end

class LazyIVar
  def initialize = @ivar = nil
  def value = @ivar ||= 42
end

class AtomValue
  def initialize = @atom = Farce::Atom.new(42)
  def value = @atom.value
end

class AtomStoreIfAbsent
  def initialize = @atom = Farce::Atom.new(nil)
  def value = @atom.store_if_absent { 42 }
end

class AtomOrStoreIfAbsent
  def initialize = @atom = Farce::Atom.new(nil)
  def value = @atom.value || @atom.store_if_absent { 42 }
end

class StrictAtomValue
  def initialize = @atom = Farce::Strict::Atom.new(42)
  def value = @atom.value
end

class StrictAtomStoreIfAbsent
  def initialize = @atom = Farce::Strict::Atom.new(nil)
  def value = @atom.store_if_absent { 42 }
end

class StrictAtomOrStoreIfAbsent
  def initialize = @atom = Farce::Strict::Atom.new(nil)
  def value = @atom.value || @atom.store_if_absent { 42 }
end


class RactorLocal
  def value
    store = Ractor.store_if_absent(:store) { ObjectSpace::WeakKeyMap.new }
    store[self] ||= 42
  end
end

class Memoized
  include Farce::Memoize[:value]
  def value = 42
end

class StrictMemoized
  include Farce::Memoize[:value, mode: :strict]
  def value = 42
end

ivar = IVar.new
lazy_ivar = LazyIVar.new
atom_value = AtomValue.new
atom_store_if_absent = AtomStoreIfAbsent.new
atom_or_store_if_absent = AtomOrStoreIfAbsent.new
strict_atom_value = StrictAtomValue.new
strict_atom_store_if_absent = StrictAtomStoreIfAbsent.new
strict_atom_or_store_if_absent = StrictAtomOrStoreIfAbsent.new
ractor_local = RactorLocal.new
memoized = Memoized.new
strict_memoized = StrictMemoized.new

Benchmark.ips do |x|
  x.report("IVar") { ivar.value }
  x.report("LazyIVar") { lazy_ivar.value }
  x.report("AtomValue") { atom_value.value }
  x.report("AtomStoreIfAbsent") { atom_store_if_absent.value }
  x.report("AtomOrStoreIfAbsent") { atom_or_store_if_absent.value }
  x.report("StrictAtomValue") { strict_atom_value.value }
  x.report("StrictAtomStoreIfAbsent") { strict_atom_store_if_absent.value }
  x.report("StrictAtomOrStoreIfAbsent") { strict_atom_or_store_if_absent.value }
  x.report("RactorLocal") { ractor_local.value }
  x.report("Memoized") { memoized.value }
  x.report("StrictMemoized") { strict_memoized.value }
  
  x.compare!
end
