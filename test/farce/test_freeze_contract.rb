# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "json"
require "yaml"

module Farce
  class TestFreezeContract < Test
    include Helpers::FreezeContract
    include Helpers::InternalTestHelpers

    OWNED_CONTAINER_TYPES = [
      Atom,
      Strict::Atom,
      Strict::WeakAtom,
      Map,
      Strict::Map,
      TreeMap,
      Strict::TreeMap,
      LRUMap,
      Strict::LRUMap,
      LFUMap,
      Strict::LFUMap,
      WeakKeyMap,
      Strict::WeakKeyMap,
      Strict::WeakValueMap,
      Strict::WeakMap,
      Vector,
      Strict::Vector
    ].freeze

    LOCAL_CONTAINER_TYPES = [
      Local::Counter,
      Local::Flag,
      Local::Atom,
      Local::WeakAtom,
      Local::Map,
      Local::TreeMap,
      Local::LRUMap,
      Local::LFUMap,
      Local::WeakMap,
      Local::WeakKeyMap,
      Local::WeakValueMap,
      Local::Vector
    ].freeze

    def test_native_counter_and_flag_freeze_contracts
      counter = Counter.new(1)

      assert_logical_freeze(
        counter,
        read:      -> { [counter.initial, counter.value] },
        mutations: counter_mutations(counter),
      )

      flag = Flag.new(false)

      assert_logical_freeze(
        flag,
        read:      -> { flag.value },
        mutations: flag_mutations(flag),
      )
    end

    def test_owned_containers_freeze_their_logical_contents
      owned_container_cases.each do |type, object, read, mutations|
        assert_includes OWNED_CONTAINER_TYPES, type
        assert_logical_freeze(object, read:, mutations:)
      end
    end

    def test_atom_map_and_vector_cover_all_atomic_mutation_entry_points
      atom = Atom.new(:current)
      atom.freeze

      assert_frozen_mutations(atom, atom_mutations(atom))

      map = Map.new({ key: :current, nil_value: nil })
      map.freeze

      assert_frozen_mutations(map, map_mutations(map))

      vector = Vector.new([:current, nil])
      vector.freeze

      assert_frozen_mutations(vector, vector_mutations(vector))
    end

    def test_callback_reentrancy_cannot_commit_after_freezing
      atom = Atom.new(:original)
      assert_raises(FrozenError) do
        atom.update do
          atom.freeze
          :replacement
        end
      end
      assert_equal :original, atom.value
      assert_predicate atom, :frozen?

      map = Map.new({ key: :original })
      assert_raises(FrozenError) do
        map.update(:key) do
          map.freeze
          :replacement
        end
      end
      assert_equal :original, map[:key]
      assert_predicate map, :frozen?

      vector = Vector.new([:original])
      assert_raises(FrozenError) do
        vector.update(0) do
          vector.freeze
          :replacement
        end
      end
      assert_equal :original, vector[0]
      assert_predicate vector, :frozen?
    end

    def test_frozen_mode_aware_writes_do_not_transfer_inputs
      atom = Atom.new(:original, mode: :move)
      atom.freeze
      atom_value = ModePayload.new(:atom)
      assert_raises(FrozenError) { atom.store(atom_value) }
      assert_equal :atom, atom_value.value

      map = Map.new({ key: :original }, mode: :move)
      map.freeze
      map_value = ModePayload.new(:map)
      assert_raises(FrozenError) { map.store(:key, map_value) }
      assert_equal :map, map_value.value

      vector = Vector.new([:original], mode: :move)
      vector.freeze
      vector_value = ModePayload.new(:vector)
      assert_raises(FrozenError) { vector.store(0, vector_value) }
      assert_equal :vector, vector_value.value
    end

    def test_container_freeze_is_shallow
      values = [Counter.new, Counter.new, Counter.new]
      containers = [
        Atom.new(values[0], mode: :raise),
        Map.new({ key: values[1] }, mode: :raise),
        Vector.new([values[2]], mode: :raise)
      ]

      containers.each(&:freeze)
      values.each do |value|
        refute_predicate value, :frozen?
        assert_same value, value.increment
      end
    end

    def test_frozen_contents_remain_serializable
      atom = Atom.new(:value)
      map = Map.new({ key: :value })
      [atom, map].each(&:freeze)

      assert_equal "value", JSON.parse(atom.to_json)
      assert_equal({ "key" => "value" }, JSON.parse(map.to_json))
      assert_includes YAML.dump(atom), "value"
      assert_includes YAML.dump(map), "key"
    end

    def test_lru_and_lfu_reads_remain_available_without_policy_updates
      [LRUMap, Strict::LRUMap, LFUMap, Strict::LFUMap].each do |type|
        map = type.new({ one: 1, two: 2 }, max_size: 2)
        before = map.to_a
        map.freeze

        assert_equal 1, map[:one]
        assert_equal 2, map.fetch(:two)
        assert_equal before, map.to_a
        assert_raises(FrozenError) { map[:three] = 3 }
      end
    end

    def test_logical_freeze_copy_states_use_independent_storage
      copy_cases.each do |source, read, mutate|
        assert_frozen_copy_states(source, read:, mutate:)
      end
    end

    def test_frozen_objects_keep_identity_and_state_across_ractors
      return unless Internal.native_ractors?

      [Counter.new(2), Flag.new(true), Atom.new(:value), Map.new({ key: :value }),
       Vector.new([:value])].each do |object|
        object.freeze
        worker = Ractor.new(object) do |shared|
          value = case shared
                  when Farce::Counter, Farce::Flag, Farce::Atom then shared.value
                  when Farce::Abstract::Map                    then shared[:key]
                  when Farce::Abstract::Vector                 then shared[0]
                  end
          [shared.object_id, shared.frozen?, value].freeze
        end

        assert_equal [object.object_id, true, read_frozen_value(object)], ractor_value(worker)
      end
    end

    def test_local_freeze_state_applies_to_existing_and_future_fiber_scopes
      local_container_cases.each do |type, object, read, mutate|
        assert_includes LOCAL_CONTAINER_TYPES, type
        refute_predicate object, :frozen?
        assert Ractor.shareable?(object)

        existing_scope = Fiber.new do
          before = read.call(object)
          Fiber.yield before
          begin
            mutate.call(object)
            :mutated
          rescue StandardError => e
            [e.class, read.call(object)]
          end
        end

        expected = read.call(object)

        assert_equal expected, existing_scope.resume
        assert_same object, object.freeze
        assert_predicate object, :frozen?
        assert_equal [FrozenError, expected], existing_scope.resume

        future_scope = Fiber.new do
          mutate.call(object)
          :mutated
        rescue StandardError => e
          [e.class, read.call(object)]
        end

        assert_equal [FrozenError, expected], future_scope.resume
        assert_equal expected, read.call(object)
      end
    end

    def test_local_freeze_state_applies_to_a_new_ractor_scope
      return unless Internal.native_ractors?

      map = Local::Map.new({ key: :initial }, scope: :ractor)
      map.freeze
      worker = Ractor.new(map) do |shared|
        error = begin
          shared[:key] = :changed
          nil
        rescue StandardError => e
          e.class.name
        end
        [shared.object_id, shared.frozen?, shared[:key], error].freeze
      end

      assert_equal [map.object_id, true, :initial, "FrozenError"], ractor_value(worker)
      assert_equal :initial, map[:key]
    end

    def test_lazy_resolves_then_freezes_its_slot
      calls = Counter.new
      lazy = Lazy.new(self: calls) do
        increment
        Map.new
      end

      refute_predicate lazy, :frozen?
      assert_same lazy, lazy.freeze
      assert_predicate lazy, :frozen?
      assert_equal 1, calls.value
      value = lazy.value

      refute_predicate value, :frozen?
      assert Ractor.shareable?(value)
      assert_same value, lazy.value
      assert_equal 1, calls.value
    end

    def test_local_lazy_rejects_freeze_without_resolving
      calls = Counter.new
      lazy = Local::Lazy.new(self: calls) do
        increment
        :value
      end

      assert_freeze_rejected(lazy)
      assert_equal 0, calls.value
      assert_equal :value, lazy.value
      assert_equal 1, calls.value
    end

    def test_service_objects_reject_freeze
      objects = service_objects

      objects.each do |object|
        assert_freeze_rejected(object)
      end

      assert_freeze_rejected(MainScheduler)
    ensure
      objects&.each { close_service(it) }
    end

    def test_every_generated_port_class_rejects_freeze
      ModeManager::MODES.each do |mode|
        [false, true].each do |auto_local|
          port = Port[mode, auto_local:].new

          assert_freeze_rejected(port)
          port.close
        end
      end
    end

    def test_rejected_freeze_leaves_representative_services_live
      queue = Queue.new

      assert_freeze_rejected(queue)
      assert queue.push(:value)
      assert_equal :value, queue.pop

      lock = Lock.new

      assert_freeze_rejected(lock)
      assert_equal(:locked, lock.synchronize { :locked })

      signal = Signal.new
      generation = signal.generation

      assert_freeze_rejected(signal)
      assert_operator signal.broadcast, :>, generation
    ensure
      queue&.close
    end

    def test_immutable_descriptors_remain_frozen
      copied_payload = []
      local_payload = []
      descriptors = [
        ModeManager.new,
        Envelope::Share.new([].freeze),
        Envelope::Copy.new(copied_payload),
        Envelope::Local.new(local_payload)
      ]

      descriptors.each do |descriptor|
        assert_predicate descriptor, :frozen?
        assert_same descriptor, descriptor.freeze
      end

      refute_predicate copied_payload, :frozen?
      refute_predicate local_payload, :frozen?
      refute_predicate descriptors[2].value, :frozen?
      assert_same local_payload, descriptors[3].value
    end

    def test_frozen_weak_contents_can_still_be_collected
      atom = build_frozen_weak_atom

      assert_frozen_weak_atom_collects(atom)

      map, retained_key = build_frozen_weak_value_map

      assert_frozen_weak_map_collects(map)
      assert retained_key
    end

    private

    def assert_frozen_mutations(object, mutations)
      mutations.each do |name, mutation|
        assert_raises(FrozenError, "#{object.class}##{name} should reject mutation", &mutation)
      end
    end

    def counter_mutations(counter)
      [
        [:store, -> { counter.store(2) }],
        [:value=, -> { counter.value = 2 }],
        [:swap, -> { counter.swap(2) }],
        [:compare_and_set, -> { counter.compare_and_set(9, 2) }],
        [:increment, -> { counter.increment }],
        [:add, -> { counter.add }],
        [:decrement, -> { counter.decrement }],
        [:subtract, -> { counter.subtract }],
        [:remove, -> { counter.remove }],
        [:increment_if_below, -> { counter.increment_if_below(0) }],
        [:decrement_if_above, -> { counter.decrement_if_above(9) }],
        [:reset, -> { counter.reset }]
      ]
    end

    def flag_mutations(flag)
      [
        [:store, -> { flag.store(true) }],
        [:value=, -> { flag.value = true }],
        [:set, -> { flag.set }],
        [:swap, -> { flag.swap(true) }],
        [:compare_and_set, -> { flag.compare_and_set(true, false) }],
        [:toggle, -> { flag.toggle }]
      ]
    end

    def atom_mutations(atom)
      [
        [:store, -> { atom.store(:replacement) }],
        [:value=, -> { atom.value = :replacement }],
        [:swap, -> { atom.swap(:replacement) }],
        [:store_if_absent, -> { atom.store_if_absent { :replacement } }],
        [:compare_and_set, -> { atom.compare_and_set(:missing, :replacement) }],
        [:update, -> { atom.update { :replacement } }],
        [:upsert, -> { atom.upsert(:initial) { :replacement } }]
      ]
    end

    def map_mutations(map)
      [
        [:store, -> { map.store(:key, :replacement) }],
        [:[]=, -> { map[:key] = :replacement }],
        [:swap, -> { map.swap(:key, :replacement) }],
        [:store_if_absent, -> { map.store_if_absent(:key) { :replacement } }],
        [:compare_and_set, -> { map.compare_and_set(:key, :missing, :replacement) }],
        [:update, -> { map.update(:key) { :replacement } }],
        [:upsert, -> { map.upsert(:key, :initial) { :replacement } }],
        [:delete, -> { map.delete(:key) }],
        [:clear, -> { map.clear }],
        [:delete_if, -> { map.delete_if { false } }],
        [:reject!, -> { map.reject! { false } }],
        [:compact!, -> { map.compact! }],
        [:keep_if, -> { map.keep_if { true } }],
        [:select!, -> { map.select! { true } }],
        [:filter!, -> { map.filter! { true } }],
        [:transform_values!, -> { map.transform_values! { it } }],
        [:merge!, -> { map.merge!({}) }]
      ]
    end

    def vector_mutations(vector)
      [
        [:store, -> { vector.store(0, :replacement) }],
        [:[]=, -> { vector[0] = :replacement }],
        [:push, -> { vector.push(:replacement) }],
        [:<<, -> { vector << :replacement }],
        [:pop, -> { vector.pop }],
        [:swap, -> { vector.swap(0, :replacement) }],
        [:store_if_absent, -> { vector.store_if_absent(0) { :replacement } }],
        [:compare_and_set, -> { vector.compare_and_set(0, :missing, :replacement) }],
        [:update, -> { vector.update(0) { :replacement } }],
        [:upsert, -> { vector.upsert(0, :initial) { :replacement } }],
        [:clear, -> { vector.clear }]
      ]
    end

    def owned_container_cases
      [
        atom_case(Atom),
        atom_case(Strict::Atom),
        atom_case(Strict::WeakAtom),
        map_case(Map),
        map_case(Strict::Map),
        map_case(TreeMap),
        map_case(Strict::TreeMap),
        map_case(LRUMap),
        map_case(Strict::LRUMap),
        map_case(LFUMap),
        map_case(Strict::LFUMap),
        map_case(WeakKeyMap),
        map_case(Strict::WeakKeyMap),
        map_case(Strict::WeakValueMap),
        map_case(Strict::WeakMap),
        vector_case(Vector),
        vector_case(Strict::Vector)
      ]
    end

    def atom_case(type)
      atom = type.new(:initial)
      [type, atom, -> { atom.value }, [[:store, -> { atom.store(:replacement) }]]]
    end

    def map_case(type)
      options = type < Abstract::BoundedMap ? { max_size: 2 } : {}
      map = type.new({ key: :initial }, **options)
      [type, map, -> { map[:key] }, [[:store, -> { map.store(:key, :replacement) }]]]
    end

    def vector_case(type)
      vector = type.new([:initial])
      [type, vector, -> { vector[0] }, [[:store, -> { vector.store(0, :replacement) }]]]
    end

    def copy_cases
      atom = Atom.new(:initial)
      map = Map.new({ key: :initial })
      vector = Vector.new([:initial])
      counter = Counter.new(1)
      flag = Flag.new(false)
      [
        [atom, lambda(&:value), ->(object) { object.value = :copy }],
        [map, ->(object) { object[:key] }, ->(object) { object[:key] = :copy }],
        [vector, ->(object) { object[0] }, ->(object) { object[0] = :copy }],
        [counter, lambda(&:value), lambda(&:increment)],
        [flag, lambda(&:value), lambda(&:set)]
      ]
    end

    def local_container_cases
      [
        local_case(Local::Counter.new(1, scope: :fiber), lambda(&:value), lambda(&:increment)),
        local_case(Local::Flag.new(false, scope: :fiber), lambda(&:value), lambda(&:set)),
        local_case(Local::Atom.new(:initial, scope: :fiber), lambda(&:value), lambda { |object|
          object.store(:changed)
        }),
        local_case(Local::WeakAtom.new(:initial, scope: :fiber), lambda(&:value), lambda { |object|
          object.store(:changed)
        }),
        local_map_case(Local::Map),
        local_map_case(Local::TreeMap),
        local_map_case(Local::LRUMap),
        local_map_case(Local::LFUMap),
        local_map_case(Local::WeakMap),
        local_map_case(Local::WeakKeyMap),
        local_map_case(Local::WeakValueMap),
        local_case(Local::Vector.new([:initial], scope: :fiber), ->(object) { object[0] }, lambda { |object|
          object.store(0, :changed)
        })
      ]
    end

    def local_case(object, read, mutate)
      [object.class, object, read, mutate]
    end

    def local_map_case(type)
      options = type < Abstract::BoundedMap ? { max_size: 2 } : {}
      object = type.new({ key: :initial }, scope: :fiber, **options)
      local_case(object, ->(map) { map[:key] }, ->(map) { map.store(:key, :changed) })
    end

    def read_frozen_value(object)
      case object
      when Counter, Flag, Atom then object.value
      when Abstract::Map       then object[:key]
      when Abstract::Vector    then object[0]
      end
    end

    def service_objects
      @service_objects ||= [
        Queue.new,
        Strict::Queue.new,
        Local::Queue.new,
        PriorityQueue.new,
        Strict::PriorityQueue.new,
        Local::PriorityQueue.new,
        TimerQueue.new,
        Strict::TimerQueue.new,
        Local::TimerQueue.new,
        Lock.new,
        ReadWriteLock.new,
        Signal.new,
        Exchanger.new,
        Strict::Exchanger.new,
        Port.new,
        Lease.new { Object.new },
        Local::Lease.new { Object.new },
        LeasePool.new(max_size: 1) { Object.new },
        Local::LeasePool.new(max_size: 1) { Object.new },
        LeaseMap.new { {} },
        Local::LeaseMap.new { {} },
        Envelope::Move.new([]),
        Scheduler.new,
        Pool.new(max_size: 1, shrink_after: nil)
      ]
    end

    def close_service(object)
      object.close if object.respond_to?(:close)
    end

    def build_frozen_weak_atom
      Thread.new do
        atom = Strict::WeakAtom.new(Object.new.freeze)
        atom.freeze
        atom
      end.value
    end

    def build_frozen_weak_value_map
      map = Strict::WeakValueMap.new
      key = Object.new.freeze
      Thread.new do
        map[key] = Object.new.freeze
        map.freeze
      end.join
      [map, key]
    end

    def assert_frozen_weak_atom_collects(atom)
      50.times do
        collect_weak_references
        return assert_nil(atom.value) if atom.value.nil?
      end

      flunk "frozen weak atom retained its value"
    end

    def assert_frozen_weak_map_collects(map)
      50.times do
        collect_weak_references
        return assert_empty(map) if map.empty?
      end

      flunk "frozen weak map retained its value"
    end

    def collect_weak_references
      2_000.times { Object.new }
      RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
      sleep 0.01
    end
  end
end
