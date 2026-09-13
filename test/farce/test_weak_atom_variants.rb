# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestWeakAtomVariants < Test
    include Helpers::InternalTestHelpers

    VARIANTS = [Strict::WeakAtom, Unshared::WeakAtom].freeze

    def run(...) = Timeout.timeout(5) { super }

    def test_hierarchy_supports_type_matching_without_a_top_level_weak_atom
      refute Farce.const_defined?(:WeakAtom, false)

      assert_equal Abstract::Atom, Atom.superclass
      assert_equal Abstract::Atom, Abstract::WeakAtom.superclass
      assert_equal Abstract::WeakAtom, Strict::WeakAtom.superclass
      assert_equal Abstract::WeakAtom, Unshared::WeakAtom.superclass

      strong = Atom.new
      strict = Strict::WeakAtom.new
      local  = Unshared::WeakAtom.new

      [strong, strict, local].each do |atom|
        assert_kind_of Abstract::Atom, atom
        assert_kind_of Abstract::Value, atom
      end

      [strict, local].each { assert_kind_of Abstract::WeakAtom, it }

      refute_kind_of Abstract::WeakAtom, strong

      assert_equal :weak, classify(strict)
      assert_equal :weak, classify(local)
      assert_equal :atom, classify(strong)
    end

    def test_variants_forward_the_direct_atom_interface
      VARIANTS.each do |klass|
        atom = klass.new(:initial)

        refute_predicate atom, :compare_by_identity?
        assert_equal :initial, atom.value
        assert_equal :initial, atom.get
        assert_equal :stored, atom.store(:stored)
        assert_equal :stored, atom.swap(:swapped)
        assert_equal :swapped, atom.value
        assert atom.compare_and_set(:swapped, :compared)
        refute atom.compare_and_set(:missing, :ignored)
        assert_equal(:updated, atom.update { :updated })
        assert_equal :upserted, atom.upsert(:initial) { :upserted }

        atom.value = nil

        assert_nil atom.value
        assert_equal(:absent, atom.store_if_absent { :absent })
        assert_equal(:absent, atom.store_if_absent { :ignored })
        assert_equal :absent, atom.wait_until_non_nil(timeout: 0) { :timeout }
        assert_equal :absent, atom.wait_until_changed(:other, timeout: 0) { :timeout }
        assert_equal :timeout, atom.wait_until_changed(:absent, timeout: 0) { :timeout }
      end
    end

    def test_variants_store_envelopes_without_implicitly_unwrapping_them
      VARIANTS.each do |klass|
        payload = Object.new
        first   = Envelope.new(payload, mode: :local)
        second  = Envelope.new(:replacement, mode: :local)
        atom    = klass.new(first)

        assert_same first, atom.value
        assert_same first, atom.get
        assert_same first, atom.swap(second)
        assert_same second, atom.value
        assert_same payload, first.value
      end
    end

    def test_variants_do_not_retain_values
      VARIANTS.each do |klass|
        atom = build_weak_atom(klass)

        assert_collects_value(atom)
      end
    end

    def test_timeout_fallback_is_returned_directly
      VARIANTS.each do |klass|
        atom     = klass.new(:current)
        entered  = Thread::Queue.new
        release  = Thread::Queue.new
        fallback = Envelope.new(Object.new, mode: :local)
        updater  = Thread.new do
          atom.update do |current|
            entered << true
            release.pop
            current
          end
        end
        entered.pop

        assert_same fallback, atom.get(timeout: 0) { fallback }
      ensure
        release&.push(true)
        updater&.join
      end
    end

    def test_variants_do_not_accept_transfer_modes
      VARIANTS.each do |klass|
        assert_raises(ArgumentError) { klass.new(mode: :copy) }

        atom = klass.new

        assert_raises(ArgumentError) { atom.store(:value, mode: :copy) }
        assert_raises(ArgumentError) { atom.swap(:value, mode: :copy) }
        assert_raises(ArgumentError) { atom.store_if_absent(mode: :copy) { :value } }
        assert_raises(ArgumentError) { atom.compare_and_set(nil, :value, mode: :copy) }
        assert_raises(ArgumentError) { atom.update(mode: :copy) { :value } }
        assert_raises(ArgumentError) { atom.upsert(:value, mode: :copy) { :replacement } }
      end
    end

    def test_comparison_can_use_identity
      VARIANTS.each do |klass|
        value = "value".dup.freeze
        equal = "value".dup.freeze
        atom  = klass.new(value, compare_by_identity: true)

        assert_predicate atom, :compare_by_identity?
        refute atom.compare_and_set(equal, :replacement)
        assert atom.compare_and_set(value, :replacement)
      end
    end

    def test_strict_variant_is_shareable
      atom = Strict::WeakAtom.new(:value)

      assert_instance_of Internal::WeakAtom, atom.instance_variable_get(:@atom)
      assert_predicate atom, :ractor_shareable?
      assert_predicate atom, :frozen?
      assert Ractor.shareable?(atom)
    end

    def test_strict_variant_runs_updates_in_the_requesting_ractor
      skip "native ractors unavailable" unless Internal.native_ractors?

      atom = Strict::WeakAtom.new(0)
      worker = Ractor.new(atom) do |shared|
        local = []
        result = shared.update do |current|
          local << :called
          current + 1
        end
        [result, local.length]
      end

      assert_equal [1, 1], ractor_value(worker)
      assert_equal 1, atom.value
    end

    def test_strict_variant_rejects_explicitly_unshareable_values
      atom        = Strict::WeakAtom.new(:current)
      unshareable = Unshared::Queue.new

      assert_raises(Ractor::IsolationError) { Strict::WeakAtom.new(unshareable) }
      assert_raises(Ractor::IsolationError) { atom.store(unshareable) }
      assert_raises(Ractor::IsolationError) { atom.swap(unshareable) }

      atom.store(nil)

      assert_raises(Ractor::IsolationError) { atom.store_if_absent { unshareable } }

      atom.store(:current)

      assert_raises(Ractor::IsolationError) { atom.compare_and_set(unshareable, :replacement) }
      assert_raises(Ractor::IsolationError) { atom.compare_and_set(:current, unshareable) }
      assert_raises(Ractor::IsolationError) { atom.update { unshareable } }
      assert_raises(Ractor::IsolationError) { atom.upsert(unshareable) { :replacement } }
      assert_raises(Ractor::IsolationError) { atom.upsert(:initial) { unshareable } }
      assert_raises(Ractor::IsolationError) { atom.wait_until_changed(unshareable, timeout: 0) }

      assert_equal :current, atom.value
    end

    def test_unshared_variant_accepts_mutable_values_and_stays_unshareable
      value = []
      atom  = Unshared::WeakAtom.new(value)

      assert_instance_of Internal::UnsharedWeakAtom, atom.instance_variable_get(:@atom)
      assert_same value, atom.value
      refute_predicate atom, :ractor_shareable?
      refute Ractor.shareable?(atom)
      assert_raises(NoMethodError) { atom.freeze }
    end

    private

    def build_weak_atom(klass)
      # Build the value on a disposable native stack. CRuby conservatively
      # scans C stack slots, which can otherwise retain a stale reference.
      Thread.new do
        value = Object.new
        value.freeze if klass == Strict::WeakAtom
        klass.new(value)
      end.value
    end

    def collect_garbage
      RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
    end

    def assert_collects_value(atom)
      20.times do
        2_000.times { Object.new }
        collect_garbage
        return assert_nil(atom.value) if atom.value.nil?
        sleep 0.01
      end

      flunk "weak atom value remained reachable after repeated full collections"
    end

    def classify(atom)
      case atom
      when Abstract::WeakAtom then :weak
      when Abstract::Atom     then :atom
      end
    end
  end
end
