# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLocal < Test
    include Helpers::InternalTestHelpers

    MAPS = [Local::Map, Local::TreeMap, Local::WeakMap, Local::WeakKeyMap, Local::WeakValueMap].freeze
    QUEUES = [Local::Queue, Local::PriorityQueue, Local::TimerQueue].freeze
    CONTAINERS = [*MAPS, *QUEUES, Local::Vector, Local::Atom, Local::WeakAtom].freeze

    def test_shareable_scoped_subclasses
      CONTAINERS.each do |klass|
        object = klass.new
        base = klass == Local::Map ? Abstract::ConcurrentMap : Abstract.const_get(klass.name.split("::").last)

        assert_kind_of base, object
        assert_kind_of Local::Scoped, object
        assert_equal :ractor, object.scope
        assert_predicate object, :frozen?
        assert_predicate object, :ractor_shareable?
        assert Ractor.shareable?(object)
      end
    end

    def test_shareable_configuration_does_not_need_an_envelope
      objects = CONTAINERS.map(&:new)
      objects << Local::Lazy.new(Array)
      objects << Local::Map.new({ key: 1 }.freeze, compare_by_identity: true)
      objects << Local::PriorityQueue.new(capacity: 4, default_priority: 2, order: :descending)
      objects.each do |object|
        configuration = object.instance_variable_get(:@configuration)

        assert_instance_of Array, configuration
        assert Ractor.shareable?(configuration)
        assert_predicate configuration, :frozen?
      end
    end

    def test_invalid_scopes
      [*CONTAINERS, Local::Lazy].each do |klass|
        [:global, :invalid, "thread", nil, Thread].each do |scope|
          assert_raises(ArgumentError) { klass.new(scope:) }
        end
      end
    end

    def test_map_operations_keep_mutable_values
      MAPS.each do |klass|
        map = klass.new
        value = []
        map[:key] = value

        assert_same value, map[:key]
        assert_same value, map.fetch(:key)
        assert_equal [[:key, value]], map.each.to_a
        assert_same(map, map.each { |pair| assert_equal [:key, value], pair })
        assert_same map, map.clear
        assert_empty map
      end
    end

    def test_concurrent_map_operations
      map = Local::Map.new(compare_by_identity: true)
      key = []
      value = []

      assert_same value, map.store_if_absent(key) { value }
      assert map.compare_and_set(key, value, :changed)
      assert_equal :changed, map.get(key)
      assert_equal :updated, map.update(key) { :updated }
      assert_predicate map, :compare_keys_by_identity?
      assert_predicate map, :compare_values_by_identity?
      refute map.key?([])
    end

    def test_backing_map_is_stored_directly_in_storage
      map = Local::Map.new

      assert_instance_of Internal::UnsharedMap, Internal::Storage[map]
    end

    def test_initial_contents_and_options
      map = Local::Map.new({ key: [] }, compare_values_by_identity: true, scope: :fiber)
      map[:extra] = :parent
      result = Fiber.new { [map.keys, map.compare_values_by_identity?] }.resume

      assert_equal [[:key], true], result
      assert_equal %i[key extra], map.keys
      vector = Local::Vector.new([:first], compare_by_identity: true)

      assert_equal :first, vector[0]
      assert_predicate vector, :compare_by_identity?
      tree = Local::TreeMap.new({ 2 => [], 1 => [] })

      assert_equal [1, 2], tree.keys
      assert_raises(ArgumentError) { Local::PriorityQueue.new(order: :invalid) }
      assert_raises(ArgumentError) { Local::Vector.new(compare_by_identity: :invalid) }
    end

    def test_containers_are_isolated_between_fibers_and_ractors
      CONTAINERS.each do |klass|
        %i[fiber ractor].each do |scope|
          object = klass.new(scope:)
          retained = store_mutable(object)
          if scope == :fiber
            assert Fiber.new { empty_container?(object) }.resume
          else
            worker = Ractor.new(object) do |local|
              before = local.is_a?(Abstract::Atom) ? local.value.nil? : local.empty?
              case local
              when Abstract::Map then local[:child] = []
              when Abstract::Atom then local.value = []
              else local.push([])
              end
              before
            end

            assert ractor_value(worker)
          end

          refute empty_container?(object)
          assert retained
        end
      end
    end

    def test_thread_scope_is_shared_by_fibers_but_not_threads
      map = Local::Map.new(scope: :thread)
      map[:parent] = []

      assert_same map[:parent], Fiber.new { map[:parent] }.resume
      assert Thread.new { map.empty? }.value
    end

    def test_thread_group_scope
      map = Local::Map.new(scope: :thread_group)
      map[:parent] = []
      group = ThreadGroup.new
      result = Thread.new do
        before = map.key?(:parent)
        group.add(Thread.current)
        isolated = map.empty?
        map[:child] = []
        [before, isolated, Thread.new { map.key?(:child) }.value]
      end.value

      assert_equal [true, true, true], result
      refute map.key?(:child)
    end

    def test_fiber_storage_scope
      map = Local::Map.new(scope: :fiber_storage)
      map[:parent] = []

      assert Fiber.new { map.key?(:parent) }.resume
      assert Fiber.new(storage: {}) { map.empty? }.resume
    end

    def test_queues_use_scoped_signals_and_lifecycle
      QUEUES.each do |klass|
        queue = klass.new(capacity: 1, track_age: true, scope: :fiber)
        value = []

        assert queue.push(value)
        assert_predicate queue, :full?
        refute queue.try_push(:full)
        assert_predicate queue, :age_tracking?
        assert_equal 1, queue.capacity
        assert_same queue, queue.seal
        assert_same value, queue.pop
        assert_predicate queue, :closed?
        assert Fiber.new { queue.empty? && !queue.closed? }.resume
        assert_raises(TypeError) { queue.dup }
      end
    end

    def test_queue_waiting_with_shared_thread_scope
      QUEUES.each do |klass|
        queue = klass.new
        value = []
        worker = Thread.new { queue.pop(timeout: 2) }
        queue.push(value)

        assert_same value, worker.value
      ensure
        worker&.kill&.join
      end
    end

    def test_ordered_queues_allocate_only_on_first_use_in_each_scope
      [Local::PriorityQueue, Local::TimerQueue].each do |klass|
        queue = klass.new(scope: :fiber)
        storage = Internal::Storage.scope(:fiber)

        refute storage.key?(queue)
        if queue.is_a?(Local::PriorityQueue)
          assert_equal :ascending, queue.order
          assert_equal 0, queue.default_priority
          refute storage.key?(queue)
        end

        value = []
        queue.push(value)

        assert storage.key?(queue)
        assert_same value, queue.pop
        Fiber.new do
          other_storage = Internal::Storage.scope(:fiber)

          refute other_storage.key?(queue)
          assert_empty queue
          assert other_storage.key?(queue)
        end.resume
      end
    end

    def test_priority_settings_are_shared_without_allocating_a_scoped_queue
      priority = "default"
      queue = Local::PriorityQueue.new(default_priority: priority, order: :descending)

      assert_same priority, queue.default_priority
      assert_equal :descending, queue.order
      refute Internal::Storage.ractor.key?(queue)
      worker = Ractor.new(queue) do |local|
        [local.default_priority, local.order, Internal::Storage.ractor[local].nil?]
      end

      assert_equal [priority, :descending, true], ractor_value(worker)
    end

    def test_priority_queue_rejects_unshareable_default_priority
      return unless Internal.native_ractors?
      priority = []

      assert_raises(Ractor::IsolationError) { Local::PriorityQueue.new(default_priority: priority) }
      refute_predicate priority, :frozen?
    end

    def test_priority_order_and_timer_readiness
      queue = Local::PriorityQueue.new(default_priority: 3, order: :descending)
      queue.push(:default)
      queue.push(:first, priority: 5)

      assert_equal :first, queue.peek
      assert_equal 5, queue.first_priority
      assert_equal 3, queue.last_priority
      assert_equal :first, queue.pop
      assert_equal :default, queue.pop
      timer = Local::TimerQueue.new
      timer.push(:later, delay: 60)

      assert_nil timer.try_pop
      refute timer.wait_pop(timeout: 0)
      assert_equal :later, timer.peek
      assert timer.delete(:later, at: timer.first_timestamp)
    end

    def test_vector_and_weak_atom_operations
      vector = Local::Vector.new
      value = []

      assert_same vector, vector.push(value)
      assert_same value, vector[0]
      assert vector.compare_and_set(0, value, :changed)
      assert_equal :changed, vector.pop
      atom = Local::WeakAtom.new(value, compare_by_identity: true)

      assert_same value, atom.value
      assert atom.compare_and_set(value, :changed)
      assert_equal :changed, atom.swap(nil)
      assert_nil atom.value
    end

    def test_lazy_caches_mutable_nil_and_false_results
      [nil, false, :mutable].each do |result|
        calls = Counter.new
        lazy = Local::Lazy.new do
          calls.increment
          result == :mutable ? [] : result
        end

        assert Ractor.shareable?(lazy)
        assert_kind_of Abstract::Lazy, lazy
        assert_equal 0, calls.value
        first = lazy.value

        first.nil? ? assert_nil(lazy.value) : assert_same(first, lazy.value)

        assert_equal 1, calls.value
      end
    end

    def test_lazy_initializes_once_under_contention
      calls = Counter.new
      lazy = Local::Lazy.new do
        calls.increment
        Thread.pass
        []
      end
      workers = 8.times.map { Thread.new { lazy.value } }
      values = workers.map(&:value)

      values.each { assert_same values.first, it }

      assert_equal 1, calls.value
    ensure
      workers&.each { it.kill.join }
    end

    def test_lazy_retries_failed_factory
      calls = Counter.new
      lazy = Local::Lazy.new do
        raise "not ready" if calls.increment == 1
        []
      end

      assert_raises(RuntimeError) { lazy.value }
      assert_empty lazy.value
      assert_equal 2, calls.value
    end

    def test_lazy_factory_and_scope_isolation
      lazy = Local::Lazy.new(Array, scope: :fiber)
      lazy.value << :parent

      assert_empty Fiber.new { lazy.value }.resume
      assert_equal [:parent], lazy.value
      lazy = Local::Lazy.new { [] }
      lazy.value << :parent
      worker = Ractor.new(lazy) do |local|
        before = local.value.dup
        local.value << :child
        [before, local.value]
      end

      assert_equal [[], [:child]], ractor_value(worker)
      assert_equal [:parent], lazy.value
      assert_raises(ArgumentError) { Local::Lazy.new(Array) { [] } }
    end

    private

    def store_mutable(object)
      value = []
      case object
      when Abstract::Map then object[:parent] = value
      when Abstract::Atom then object.value = value
      else object.push(value)
      end
      value
    end

    def empty_container?(object)
      object.is_a?(Abstract::Atom) ? object.value.nil? : object.empty?
    end
  end
end
