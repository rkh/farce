# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestLocalFreeze < Test
    include Helpers::FreezeContract
    include Helpers::InternalTestHelpers

    def test_freeze_reaches_existing_and_future_fiber_scopes
      local_data_cases(scope: :fiber).each do |object, read, mutate|
        existing = Fiber.new do
          before = read.call(object)
          Fiber.yield before
          mutation_result(object, read, mutate)
        end
        expected = read.call(object)

        assert_equal expected, existing.resume
        assert_same object, object.freeze
        assert_predicate object, :frozen?
        assert_equal [FrozenError, expected], existing.resume

        future = Fiber.new { mutation_result(object, read, mutate) }

        assert_equal [FrozenError, expected], future.resume
        assert_equal expected, read.call(object)
      end
    end

    def test_freeze_reaches_a_future_ractor_scope
      return unless Internal.native_ractors?

      map = Local::Map.new({ key: :initial }, scope: :ractor)
      map.freeze
      worker = Ractor.new(map) do |local|
        error = begin
          local[:key] = :changed
          nil
        rescue StandardError => e
          e.class.name
        end
        [local.object_id, local.frozen?, local[:key], error].freeze
      end

      assert_equal [map.object_id, true, :initial, "FrozenError"], ractor_value(worker)
      assert_equal :initial, map[:key]
    end

    def test_callback_cannot_commit_after_freezing_the_handle
      atom = Local::Atom.new(:original)
      assert_raises(FrozenError) do
        atom.update do
          atom.freeze
          :replacement
        end
      end
      assert_equal :original, atom.value

      map = Local::Map.new({ key: :original })
      assert_raises(FrozenError) do
        map.update(:key) do
          map.freeze
          :replacement
        end
      end
      assert_equal :original, map[:key]

      vector = Local::Vector.new([:original])
      assert_raises(FrozenError) do
        vector.update(0) do
          vector.freeze
          :replacement
        end
      end
      assert_equal :original, vector[0]
    end

    def test_copies_have_independent_storage_and_freeze_state
      local_data_cases.each do |source, read, mutate|
        expected = read.call(source)
        source.freeze
        duplicated = source.dup
        cloned = source.clone
        mutable_clone = source.clone(freeze: false)

        refute_predicate duplicated, :frozen?
        assert_predicate cloned, :frozen?
        refute_predicate mutable_clone, :frozen?
        [duplicated, cloned, mutable_clone].each do |copy|
          assert Ractor.shareable?(copy)
          assert_equal expected, read.call(copy)
        end

        mutate.call(duplicated)
        mutate.call(mutable_clone)

        refute_equal expected, read.call(duplicated)
        refute_equal expected, read.call(mutable_clone)
        assert_equal expected, read.call(source)
        assert_equal expected, read.call(cloned)
        assert_raises(FrozenError) { mutate.call(cloned) }
      end
    end

    def test_normalized_map_keeps_configuration_in_future_scopes
      normalizer = Ractor.shareable_proc { |key| key.to_s.downcase }
      map = Local::Map.new({ "Key" => :initial }, normalize_keys: normalizer, scope: :fiber)

      assert_equal :initial, map[:KEY]
      map.freeze

      result = Fiber.new do
        value = map[:KEY]
        error = begin
          map[:other] = :changed
          nil
        rescue StandardError => e
          e.class
        end
        [value, error]
      end.resume

      assert_equal [:initial, FrozenError], result
      assert_equal :initial, map["key"]
    end

    def test_nonmutating_map_transformations_return_mutable_maps
      map = Local::Map.new({ one: 1, two: 2 })
      map.freeze

      transformed = map.transform_values { it * 10 }

      refute_predicate transformed, :frozen?
      assert_equal({ one: 10, two: 20 }, transformed.to_h)
      transformed[:one] = 11

      assert_equal 11, transformed[:one]
      assert_equal 1, map[:one]
    end

    def test_frozen_bounded_map_reads_do_not_update_policy
      [Local::LRUMap, Local::LFUMap].each do |type|
        map = type.new({ one: 1, two: 2 }, max_size: 2)
        before = map.to_a
        map.freeze

        assert_equal 1, map[:one]
        assert_equal 2, map.fetch(:two)
        assert_equal before, map.to_a
        assert_raises(FrozenError) { map[:three] = 3 }
      end
    end

    def test_frozen_weak_storage_does_not_retain_values
      atom = Thread.new do
        Local::WeakAtom.new.tap do |local|
          local.store(Object.new)
          local.freeze
        end
      end.value
      map = Thread.new do
        Local::WeakValueMap.new.tap do |local|
          local[:key] = Object.new
          local.freeze
        end
      end.value

      50.times do
        2_000.times { Object.new }
        RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
        break if atom.value.nil? && map.empty?
      end

      assert_nil atom.value
      assert_empty map
    end

    def test_local_services_reject_freeze_and_remain_live
      queues = [Local::Queue.new, Local::PriorityQueue.new, Local::TimerQueue.new]
      lease = Local::Lease.new { [] }
      pool = Local::LeasePool.new(max_size: 1) { [] }
      leases = Local::LeaseMap.new { { key: [] } }
      lazy = Local::Lazy.new { [] }
      services = [*queues, lease, pool, leases, lazy]

      services.each { assert_freeze_rejected(it) }
      queues.each do |queue|
        assert queue.push(:value)
        assert_equal :value, queue.pop
      end
      assert_equal(:lease, lease.checkout { :lease })
      assert_equal(:pool, pool.checkout { :pool })
      assert_equal :map, leases.checkout(:key) { :map }
      assert_empty lazy.value
    ensure
      queues&.each(&:close)
    end

    def test_local_lazy_copies_share_the_slot_without_becoming_frozen
      lazy = Local::Lazy.new { [] }
      value = lazy.value

      [lazy.dup, lazy.clone, lazy.clone(freeze: false)].each do |copy|
        refute_predicate copy, :frozen?
        assert_same value, copy.value
        assert Ractor.shareable?(copy)
      end
      assert_raises(TypeError) { lazy.clone(freeze: true) }
    end

    private

    def mutation_result(object, read, mutate)
      mutate.call(object)
      :mutated
    rescue StandardError => e
      [e.class, read.call(object)]
    end

    def local_data_cases(scope: :ractor)
      [
        [Local::Counter.new(1, scope:), lambda(&:value), lambda(&:increment)],
        [Local::Flag.new(false, scope:), lambda(&:value), lambda(&:set)],
        [Local::Atom.new(:initial, scope:), lambda(&:value), ->(object) { object.store(:changed) }],
        [Local::WeakAtom.new(:initial, scope:), lambda(&:value), ->(object) { object.store(:changed) }],
        local_map_case(Local::Map, scope:),
        local_map_case(Local::TreeMap, scope:),
        local_map_case(Local::LRUMap, scope:),
        local_map_case(Local::LFUMap, scope:),
        local_map_case(Local::WeakMap, scope:),
        local_map_case(Local::WeakKeyMap, scope:),
        local_map_case(Local::WeakValueMap, scope:),
        [Local::Vector.new([:initial], scope:), ->(object) { object[0] }, lambda { |object|
          object.store(0, :changed)
        }]
      ]
    end

    def local_map_case(type, scope:)
      options = type < Abstract::BoundedMap ? { max_size: 2 } : {}
      map = type.new({ key: :initial }, scope:, **options)
      [map, ->(object) { object[:key] }, ->(object) { object.store(:key, :changed) }]
    end
  end
end
