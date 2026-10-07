# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

# Every stream in this file is produced by the test itself.
# rubocop:disable Security/MarshalLoad

module Farce
  class TestMarshal < Test
    include Helpers::InternalTestHelpers
    include Helpers::WeakReferenceHelpers

    Record = Molecule.define(:first, :second)
    StrictRecord = Strict::Molecule.define(:first, :second)
    UnsharedRecord = Unshared::Molecule.define(:first, :second)
    LocalRecord = Local::Molecule.define(:first, :second)

    class NilFactory
      def self.new = nil
    end

    class ArrayFactory
      def self.new = [].freeze
    end

    class Point
      include Shareable::Immutable

      attr_reader :x

      def initialize(coordinate)
        @x = coordinate
        super()
      end
    end

    NAMESPACES = [Farce, Strict, Unshared, Local, Unsafe].freeze

    def test_scalar_variants_restore_independent_storage_and_settings
      NAMESPACES.each do |namespace|
        counter = namespace::Counter.new(3).increment(4)
        copy = round_trip(counter)

        assert_equal 7, copy.value
        assert_equal 3, copy.initial
        copy.reset

        assert_equal 3, copy.value
        assert_equal 7, counter.value

        flag = namespace::Flag.new(true)
        copy = round_trip(flag)
        copy.unset

        refute copy.value
        assert flag.value

        %i[Atom WeakAtom].each do |name|
          atom = namespace.const_get(name).new(:before, compare_by_identity: true)
          copy = round_trip(atom)

          assert_predicate copy, :compare_by_identity?
          assert copy.compare_and_set(:before, :after)
          assert_equal :before, atom.value
        end
      end
    end

    def test_vector_variants_restore_settings_and_remain_mutable
      NAMESPACES.each do |namespace|
        source = namespace::Vector.new([1, 2], compare_by_identity: true)
        copy = round_trip(source)

        assert_predicate copy, :compare_by_identity?
        copy.push(3)

        assert_equal [1, 2, 3], copy.to_a
        assert_equal [1, 2], source.to_a
      end
    end

    def test_map_variants_restore_entries_comparison_and_capacity
      NAMESPACES.each do |namespace|
        %i[Map WeakMap WeakKeyMap WeakValueMap LRUMap LFUMap TreeMap].each do |name|
          options = %i[LRUMap LFUMap].include?(name) ? { max_size: 3 } : {}
          options[:compare_values_by_identity] = true unless name == :TreeMap
          source = namespace.const_get(name).new({ a: 1, b: nil }, **options)
          copy = round_trip(source)

          assert_equal({ a: 1, b: nil }, copy.to_h)
          assert_predicate copy, :compare_values_by_identity? unless name == :TreeMap
          assert_equal 3, copy.max_size if options.key?(:max_size)
          copy[:c] = 2

          refute source.key?(:c)
        end
      end
    end

    def test_set_variants_restore_members_and_independent_storage
      NAMESPACES.each do |namespace|
        %i[Set SortedSet WeakSet].each do |name|
          source = namespace.const_get(name).new([1, 2])
          copy = round_trip(source)

          assert_equal [1, 2], copy.to_a.sort
          copy.add(3)

          refute_includes source, 3
        end
      end
    end

    def test_logical_frozen_state_is_separate_from_shareability
      [Counter.new, Flag.new, Atom.new, Strict::Atom.new, Vector.new, Strict::Vector.new,
       Map.new, TreeMap.new, LRUMap.new(max_size: 2), LFUMap.new(max_size: 2),
       Set.new, SortedSet.new, Local::Atom.new, Local::Vector.new, Local::Map.new].each do |source|
        refute_predicate round_trip(source), :frozen?
        assert_predicate round_trip(source.freeze), :frozen?
      end
    end

    def test_strict_payloads_remain_shareable
      value = ["payload"].freeze
      value = Ractor.make_shareable(value)
      [Strict::Atom.new(value), Strict::Vector.new([value]), Strict::Map.new({ value => value }),
       Strict::Set.new([value])].each do |source|
        copy = round_trip(source)

        assert Ractor.shareable?(copy)
      end
      copy = round_trip(Strict::Atom.new(value))

      assert Ractor.shareable?(copy.value)
      assert_raises(FrozenError) { copy.value << :changed }
    end

    def test_per_value_modes_survive_without_native_storage_in_the_stream
      atom = Atom.new(mode: :raise)
      atom.store([1], mode: :copy)
      vector = Vector.new(mode: :raise)
      vector.push([1], mode: :copy)
      map = Map.new(mode: :raise)
      map.store(:value, [1], mode: :copy)
      set = Set.new(mode: :raise)
      set.add([1], mode: :copy)

      [atom, vector, map, set].each do |source|
        dump = ::Marshal.dump(source)

        refute_includes dump, "Farce::Internal::"
        copy = ::Marshal.load(dump)

        assert_equal :raise, copy.mode
      end
      assert_equal [1], round_trip(atom).value
      assert_equal [[1]], round_trip(vector).to_a
      assert_equal({ value: [1] }, round_trip(map).to_h)
      assert_equal [[1]], round_trip(set).to_a
    end

    def test_copy_snapshots_include_existing_local_edits_without_opening_unread_envelopes
      source = Atom.new([])
      source.value << :edited

      assert_equal [:edited], round_trip(source).value

      envelope = Envelope::Copy.new([])
      storage = Internal::Storage.ractor

      refute storage.key?(envelope)
      round_trip(envelope)

      refute storage.key?(envelope)
    end

    def test_dumping_move_values_rejects_without_claiming_them
      envelope = Envelope::Move.new([])
      [envelope, Atom.new(envelope), Vector.new([envelope]), Map.new({ value: envelope })].each do |source|
        assert_raises(TypeError) { ::Marshal.dump(source) }
        refute_predicate envelope, :claimed?
      end
      assert_equal [], envelope.value
    end

    def test_map_normalization_is_not_applied_twice
      NAMESPACES.each do |namespace|
        %i[Map TreeMap LRUMap LFUMap WeakKeyMap].each do |name|
          options = { normalize_keys: :succ }
          options[:max_size] = 3 if %i[LRUMap LFUMap].include?(name)
          source = namespace.const_get(name).new({ 1 => :value }, **options)
          copy = round_trip(source)

          assert_equal({ 2 => :value }, copy.to_h)
          assert_equal :value, copy[1]
          copy[2] = :next

          assert_equal :next, copy[2]
        end
      end
    end

    def test_lookup_normalizers_restore_their_source
      source = Map.new({ a: 1 }, normalize_keys: { a: :canonical }.freeze)
      copy = round_trip(source)

      assert_equal 1, copy[:a]
      assert_equal({ canonical: 1 }, copy.to_h)
    end

    def test_proc_normalizers_reject_dumping
      [Unshared::Map.new(normalize_keys: ->(key) { key }),
       Unshared::Set.new(normalize: ->(value) { value })].each do |source|
        assert_raises(TypeError) { ::Marshal.dump(source) }
      end
    end

    def test_set_membership_snapshots_survive_mutation
      skip "mutable values use envelopes only with native Ractors" unless Internal.native_ractors?
      source = Set.new([[1]])
      source.first << 2
      copy = round_trip(source)

      assert_equal [[1, 2]], copy.to_a
      assert_includes copy, [1]
      refute_includes copy, [1, 2]
    end

    def test_set_identity_keys_are_reconstructed
      source = Set.new([[1], [1]], compare_by_identity: true, mode: :local)
      copy = round_trip(source)

      assert_equal 2, copy.size
      copy.each { assert_includes copy, it }

      refute_includes copy, [1]
    end

    def test_lru_order_is_preserved_without_counting_dump_as_an_access
      NAMESPACES.each do |namespace|
        source = namespace::LRUMap.new({ a: 1, b: 2, c: 3 }, max_size: 3)
        source[:a]
        copy = round_trip(source)

        assert_equal :b, copy.shift.first
        assert_equal :b, source.shift.first
        assert_equal :c, copy.shift.first
      end
    end

    def test_lfu_restoration_resets_frequencies
      NAMESPACES.each do |namespace|
        source = namespace::LFUMap.new({ a: 1, b: 2 }, max_size: 2)
        4.times { source[:a] }
        copy = round_trip(source)
        copy[:b]
        copy[:c] = 3

        refute copy.key?(:a)
        assert copy.key?(:b)
        assert_equal({ b: 2, a: 1 }, source.to_h)
      end
    end

    def test_local_current_state_and_future_scope_configuration_are_separate
      counter = Local::Counter.new(3, scope: :thread).increment(4)
      atom = Local::Atom.new(:initial, scope: :thread)
      atom.value = :current
      map = Local::Map.new({ initial: 1 }, scope: :thread)
      map[:current] = 2
      vector = Local::Vector.new([:initial], scope: :thread)
      vector.push(:current)
      set = Local::Set.new([:initial], scope: :thread)
      set.add(:current)
      copies = [counter, atom, map, vector, set].map { round_trip(it) }

      assert_equal 7, copies[0].value
      assert_equal :current, copies[1].value
      assert_equal({ initial: 1, current: 2 }, copies[2].to_h)
      assert_equal %i[initial current], copies[3].to_a
      assert_equal %i[current initial], copies[4].to_a.sort
      future = Thread.new { [copies[0].value, copies[1].value, copies[2].to_h, copies[3].to_a, copies[4].to_a] }.value

      assert_equal [3, :initial, { initial: 1 }, [:initial], [:initial]], future
    end

    def test_local_normalized_initial_entries_stay_canonical_in_future_scopes
      [Local::Map, Local::TreeMap, Local::LRUMap, Local::LFUMap].each do |type|
        options = { normalize_keys: :succ, scope: :thread }
        options[:max_size] = 3 if type <= Abstract::BoundedMap
        source = type.new({ 1 => :initial }, **options)
        source[2] = :current
        dump = ::Marshal.dump(source)

        refute_includes dump, "Farce::Internal::"
        copy = ::Marshal.load(dump)

        assert_equal({ 2 => :initial, 3 => :current }, copy.to_h)
        assert_equal({ 2 => :initial }, Thread.new { copy.to_h }.value)
      end
    end

    def test_sets_keep_private_backing_classes_out_of_the_stream
      NAMESPACES.each do |namespace|
        %i[Set SortedSet WeakSet].each do |name|
          source = namespace.const_get(name).new([1, 2], normalize: :succ)
          dump = ::Marshal.dump(source)

          refute_includes dump, "MutableTreeMap"
          refute_includes dump, "Farce::Internal::"
          copy = ::Marshal.load(dump)

          assert_equal [2, 3], copy.to_a.sort
          assert_includes copy, 1
        end
      end
    end

    def test_aliases_and_recursive_values_restore
      [Atom, Strict::Atom, Unshared::Atom].each do |type|
        source = type.new
        source.value = source
        copy = round_trip(source)

        assert_same copy, copy.value
      end
      [Vector, Strict::Vector, Unshared::Vector].each do |type|
        source = type.new
        source.push(source)
        copy = round_trip(source)

        assert_same copy, copy.first
      end
      [Map, Strict::Map, Unshared::Map].each do |type|
        source = type.new
        source[:self] = source
        copy = round_trip(source)

        assert_same copy, copy[:self]
      end
      first = Unshared::Atom.new
      second = Unshared::Vector.new([first])
      first.value = second
      copy = round_trip(first)

      assert_same copy, copy.value.first
    end

    def test_recursive_shareable_facades_reject_before_freezing_uninitialized_values
      skip "only native Ractors require structural publication" unless Internal.native_ractors?
      first = Atom.new
      second = Vector.new([first])
      first.value = second
      dump = ::Marshal.dump(first)
      error = assert_raises(TypeError) { ::Marshal.load(dump) }
      assert_match(/recursive shareable snapshots/, error.message)
      assert_same first, second.first
      assert_same second, first.value
    end

    def test_user_shareable_values_without_hooks_use_normal_marshal
      copy = round_trip(Strict::Atom.new(Point.new(3)))

      assert_equal 3, copy.value.x
      assert_predicate copy.value, :frozen?
      assert Ractor.shareable?(copy.value)
    end

    def test_loaded_shareable_containers_work_in_another_ractor
      copies = [round_trip(Counter.new(3)), round_trip(Atom.new([1])),
                round_trip(Vector.new([[2]])), round_trip(Map.new({ value: [3] })),
                round_trip(Set.new([[4]]))]
      worker = Ractor.new(*copies) do |counter, atom, vector, map, set|
        [counter.increment.value, atom.value, vector.first, map[:value], set.first]
      end

      assert_equal [4, [1], [2], [3], [4]], ractor_value(worker)
      assert_equal 4, copies.first.value
    end

    def test_records_preserve_explicit_atoms_and_shared_holders
      [Record, StrictRecord, UnsharedRecord, LocalRecord].each do |type|
        atom = Atom.new(:value, compare_by_identity: true, mode: :raise)
        source = type.new(first: atom, second: atom)
        copy, holder = round_trip([source, atom])

        assert_same holder, copy.first_atom
        assert_same holder, copy.second_atom
        assert_predicate holder, :compare_by_identity?
        assert_equal :raise, holder.mode
      end
    end

    def test_unresolved_lazy_values_are_not_evaluated
      [Lazy, Strict::Lazy, Unshared::Lazy, Local::Lazy].each do |type|
        source = type.new(ArrayFactory)
        copy = round_trip(source)

        assert_nil source.send(:internal_atom).value
        assert_nil copy.send(:internal_atom).value
        assert_equal [], copy.value
      end
      source = Unshared::Lazy.new { flunk "Marshal must not call the factory" }
      assert_raises(TypeError) { ::Marshal.dump(source) }
      assert_nil source.send(:internal_atom).value
    end

    def test_dumping_local_lazy_does_not_allocate_scoped_value_storage
      source = Local::Lazy.new(ArrayFactory, scope: :thread)
      key = source.instance_variable_get(:@state_key)
      storage = Internal::Storage.scope(:thread)

      refute storage.key?(key)
      round_trip(source)

      refute storage.key?(key)
    end

    def test_nonempty_frozen_collections_restore_frozen_backends
      NAMESPACES.reject { it == Unshared || it == Unsafe }.each do |namespace|
        collections = [namespace::Vector.new([1]), namespace::Map.new({ value: 1 }),
                       namespace::TreeMap.new({ 1 => 2 }), namespace::LRUMap.new({ a: 1 }, max_size: 2),
                       namespace::LFUMap.new({ a: 1 }, max_size: 2), namespace::Set.new([1]),
                       namespace::SortedSet.new([1])]
        collections.each do |source|
          copy = round_trip(source.freeze)

          assert_equal 1, copy.size
          assert_raises(FrozenError) { copy.clear }
        end
      end
    end

    def test_frozen_tree_maps_reject_ordered_removals_before_and_after_loading
      [TreeMap, Strict::TreeMap, Local::TreeMap].each do |type|
        source = type.new({ 1 => 2 }).freeze
        [source, round_trip(source)].each do |map|
          assert_raises(FrozenError) { map.shift }
          assert_raises(FrozenError) { map.pop }
          assert_raises(FrozenError) { map.clear }
          assert_equal({ 1 => 2 }, map.to_h)
        end
      end
    end

    def test_resolved_lazy_values_drop_the_unused_factory_and_preserve_cached_nil
      [Lazy, Strict::Lazy, Unshared::Lazy].each do |type|
        source = type.new(NilFactory)

        assert_nil source.value
        copy = round_trip(source)

        assert_nil copy.value
        refute_nil copy.send(:internal_atom).value
      end
      source = Unshared::Lazy.new { [:cached] }
      source.value

      assert_equal [:cached], round_trip(source).value
    end

    def test_lazy_references_keep_the_wrapper_without_resolving_the_holder
      [LazyRef, Strict::LazyRef, Unshared::LazyRef, Local::LazyRef].each do |type|
        source = type.new(ArrayFactory)
        copy = round_trip(source)

        assert_nil Reference.deref(source).send(:internal_atom).value
        assert_nil Reference.deref(copy).send(:internal_atom).value
        assert_equal [], copy.to_a
      end
      holder = Atom.new(:value)
      first, second, copy_holder = round_trip([Reference.new(holder), Reference.new(holder, deep: true), holder])

      assert_same copy_holder, Reference.deref(first)
      assert_same copy_holder, Reference.deref(second)
    end

    def test_references_restore_wrapper_frozen_state
      source = Reference.new(Unshared::Atom.new([]))
      copy = round_trip(source.freeze)

      assert_predicate copy, :frozen?
      Reference.deref(copy).value = []

      refute_predicate copy, :frozen?
      assert ::Kernel.instance_method(:frozen?).bind_call(copy)
    end

    def test_weak_references_preserve_live_targets_and_canonical_states
      target = []
      weak_value, weak_ref, restored_target = round_trip([WeakValue.new(target), WeakRef.new(target), target])

      assert_same restored_target, weak_value.value
      assert_same restored_target, weak_ref.__getobj__
      assert_same WeakValue.new(nil), round_trip(WeakValue.new(nil))
      assert_same WeakValue::RECYCLED, round_trip(WeakValue::RECYCLED)
      assert_same WeakRef::RECYCLED, round_trip(WeakRef::RECYCLED)
      assert_raises(WeakRefError) { round_trip(WeakRef::RECYCLED).__getobj__ }
    end

    def test_restored_weak_references_do_not_retain_their_targets
      [WeakValue, WeakRef].each do |type|
        factory = Object.new
        factory.define_singleton_method(:new) { |value| ::Marshal.load(::Marshal.dump(type.new(value))) }
        dead = collected_reference(factory)
        copy = round_trip(dead)

        refute reference_alive?(copy)
        assert_raises(WeakRefError) { type == WeakValue ? copy.value : copy.__getobj__ }
      end
    end

    def test_envelopes_and_mode_managers_restore_public_contracts
      manager = ModeManager.new(mode: :local)
      [Envelope::Copy.new([]), Envelope::Local.new([]), Envelope::Share.new([1].freeze)].each do |source|
        copy = round_trip(source)

        assert Ractor.shareable?(copy)
        assert_equal source.value, copy.value
      end
      envelope, copy_manager = round_trip([Envelope::Copy.new([], manager), manager])

      assert_same copy_manager, envelope.auto_unwrap
      assert_equal :local, copy_manager.mode
      assert Ractor.shareable?(copy_manager)
    end

    def test_stateless_services_restore_without_live_caches
      scheduler = round_trip(ThreadScheduler.new)

      assert Ractor.shareable?(scheduler)
      result = nil

      assert_same(scheduler, scheduler.execute { result = :value })
      assert_equal :value, result
      factory = Ractor.shareable_proc { Thread.new { :value } }
      assert_raises(TypeError) { ::Marshal.dump(ThreadScheduler.new(&factory)) }

      source = Deduper.new.store(Range).skip(Array)
      copy = round_trip(source)

      assert_equal [1], copy.dedup([1])
      refute_predicate copy.dedup([1]), :frozen?
      assert_same copy.dedup(1..3), copy.dedup(1..3)

      mirror = round_trip(ClassMirror.new(Object))

      assert_same Object, mirror[String]
      assert_raises(TypeError) { ::Marshal.dump(ClassMirror.new) }
      assert_raises(TypeError) { ::Marshal.dump(ClassMirror.new(Object) { :value }) }
    end

    def test_config_restores_explicit_values_without_changing_global_settings
      source = Config.new do |config|
        config.autoload_integrations = false
        config.main_thread_pool_size = 7
        config.additional_thread_pool_size = 3
        config.fiber_scheduler = :select
      end
      copy = round_trip(source)

      refute copy.autoload_integrations
      assert_equal 7, copy.main_thread_pool_size
      assert_equal 3, copy.additional_thread_pool_size
      assert_equal :select, copy.fiber_scheduler
      refute_predicate copy, :frozen?
      assert_predicate round_trip(source.freeze), :frozen?
    end

    def test_trie_builders_restore_semantic_entries_and_shared_tokens
      token = Ractor.make_shareable([:route])
      builder = Strict::Trie::Builder.new
      builder.add(["/", /(?<id>\d+)/], token)
      builder.add(["/alias"], token)
      copy, restored_token = round_trip([builder, token])
      trie = copy.build

      assert_same restored_token, trie.match("/12").first
      assert_same restored_token, trie.match("/alias").first
      assert_equal({ "id" => "12" }, trie.match("/12")[2])
      assert_raises(TypeError) { ::Marshal.dump(trie) }
      copy.add(["/new"], :new)

      assert_nil builder.build.match("/new")
    end

    def test_public_classes_have_an_explicit_or_standard_marshal_policy
      seen = {}.compare_by_identity
      visit = lambda do |namespace, path|
        return if seen[namespace]
        seen[namespace] = true
        namespace.constants(false).each do |name|
          type = namespace.const_get(name, false)
          next unless Module === type
          source = namespace.const_source_location(name, false)
          next if source && !File.expand_path(source.first).start_with?(File.expand_path("../../lib/", __dir__))
          label = "#{path}::#{name}"
          next if type == Abstract || type == Integrations

          if Class === type
            # Standard exceptions retain Ruby's message and backtrace format.
            next if type <= Exception || type == Ractor::MovedObject
            # This is an unchanged alias to a standard resolver with a live mutex.
            if type == Resolv::Hosts
              assert_raises(TypeError) { ::Marshal.dump(type.new) }
              next
            end

            assert_includes type.public_instance_methods + type.private_instance_methods, :marshal_dump, label
          end
          visit.call(type, label)
        end
      end
      visit.call(Farce, "Farce")
    end

    def test_transaction_wrappers_reject_dumping
      sources = [Atom.new, Vector.new, Map.new, TreeMap.new, Set.new, SortedSet.new,
                 Record.new(first: 1, second: 2)]

      assert(Farce.transaction(*sources) do |_transaction, *wrappers|
        wrappers.each { |wrapper| assert_raises(TypeError) { ::Marshal.dump(wrapper) } }
      end)
    end

    def test_nested_lazy_references_are_not_evaluated_during_dump
      reference = Unshared::LazyRef.new(ArrayFactory)
      holder = Reference.deref(reference)
      source = Unshared::Vector.new([reference])
      copy = round_trip(source)

      assert_nil holder.send(:internal_atom).value
      assert_nil Reference.deref(copy.first).send(:internal_atom).value
      assert_equal [], copy.first.to_a
    end

    def test_live_coordination_objects_explicitly_reject_marshal
      NAMESPACES.each do |namespace|
        %i[Queue PriorityQueue TimerQueue].each do |name|
          assert_raises(TypeError) { ::Marshal.dump(namespace.const_get(name).new) }
        end
        assert_raises(TypeError) { ::Marshal.dump(namespace::Lease.new { [] }) } unless namespace == Strict
        assert_raises(TypeError) { ::Marshal.dump(namespace::LeasePool.new(max_size: 1) { [].freeze }) }
        assert_raises(TypeError) { ::Marshal.dump(namespace::LeaseMap.new { {} }) }
      end
      [Lock.new, ReadWriteLock.new, Signal.new, Exchanger.new, Strict::Exchanger.new,
       Strict::Lease.new { [].freeze }, Port.new, Strict::Port.new, Transaction.new,
       Proxy::Register.new, Ractor.current, Ractor::Port.new, Resolv::DNS.new,
       Pool.new, Scheduler.new, Proxy.new([])].each do |source|
        assert_raises(TypeError) { ::Marshal.dump(source) }
      ensure
        source.close if source.is_a?(Port) || source.is_a?(Strict::Port) ||
          source.is_a?(Pool) || source.is_a?(Scheduler) || source.is_a?(Ractor::Port)
      end
    end

    private

    def round_trip(source)
      copy = ::Marshal.load(::Marshal.dump(source))
      assert_instance_of source.class, copy unless Reference === source || source.is_a?(WeakRef)
      copy
    end
  end
end

# rubocop:enable Security/MarshalLoad
