# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby"

require_relative "../../setup"
require "objspace"

module Farce
  module Internal
    class TestNativeLFUMap < Test
      include Helpers::InternalTestHelpers

      MAP_CLASSES = [Internal::LFUMap, Internal::ShareableLFUMap].freeze

      def test_frequency_then_recency_selects_victims
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 3)
          map[:a] = 1
          map[:b] = 2
          map[:c] = 3
          map[:a]
          map[:b]

          assert_equal [:c, 3], map.shift
          assert_equal [:a, 1], map.shift
          assert_equal [:b, 2], map.shift
        end
      end

      def test_writes_increment_and_reinsertion_resets_history
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 2)
          map[:a] = 1
          map[:b] = 2
          map[:a] = 3
          map[:b]

          assert_equal [:a, 3], map.shift

          map[:a] = 4
          map[:b]

          assert_equal [:a, 4], map.shift
          assert_equal [:b, 2], map.shift
        end
      end

      def test_new_writes_are_always_admitted
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 2)
          map[:hot] = :hot
          map[:warm] = :warm
          10.times { map[:hot] }
          3.times { map[:warm] }

          assert_equal :new, map[:new] = :new
          assert map.key?(:hot)
          assert map.key?(:new)
          refute map.key?(:warm)
          assert_equal %i[new new], map.shift
        end
      end

      def test_observation_does_not_increment_frequency
        MAP_CLASSES.each do |klass|
          map = klass.new({ a: 1, b: 2 }, max_size: 2)

          5.times do
            assert map.key?(:a)
            assert_same :a, map.getkey(:a)
            map.each.to_a
            map.keys
          end
          map[:b]
          map[:c] = 3

          refute map.key?(:a)
          assert map.key?(:b)
          assert map.key?(:c)
        end
      end

      def test_falsey_keys_values_capacity_prune_and_clear
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 3)
          map[nil] = false
          map[false] = nil
          map[:third] = 3

          refute map[nil]
          assert_nil map[false]
          assert map.key?(false)
          assert_equal 1, map.prune(to: 2)
          assert_equal 1, map.max_size = 1
          assert_equal 1, map.size
          assert_same map, map.clear
          assert_empty map
          assert_equal 1, map.max_size
        end
      end

      def test_zero_capacity_validates_without_retaining
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 0)
          result = map[nil] = false

          refute result
          assert_empty map
          assert_nil map.shift
        end

        shared = Internal::ShareableLFUMap.new(max_size: 0)
        assert_raises(Ractor::IsolationError) { shared[Object.new] = :value }
        assert_raises(Ractor::IsolationError) { shared[:key] = Object.new }
      end

      def test_string_preparation_and_identity
        original = +"key"
        map = Internal::ShareableLFUMap.new(max_size: 1)
        prepared = map.prepare_key(original)
        map[prepared] = :value
        original.replace("changed")

        assert_predicate prepared, :frozen?
        assert_equal :value, map["key"]

        key = +"identity"
        local = Internal::LFUMap.new(max_size: 1, compare_keys_by_identity: true)
        local[key] = :value

        assert_same key, local.getkey(key)
        assert_nil local[+"identity"]
      end

      def test_gc_compaction_and_frequency_bucket_churn
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 32)
          2_000.times do |index|
            value = "value-#{index}"
            value.freeze if klass == Internal::ShareableLFUMap
            map["key-#{index}"] = value
            (index % 4).times { map["key-#{index}"] }
          end

          GC.start
          if GC.respond_to?(:verify_compaction_references)
            GC.verify_compaction_references(double_heap: true, toward: :empty)
          elsif GC.respond_to?(:compact)
            GC.compact
          end

          assert_equal 32, map.size
          map.each { |key, value| assert_equal value, map[key] }
          32.times { refute_nil map.shift }
          assert_empty map
        end
      end

      def test_policy_specific_entry_and_bucket_memory_accounting
        pointer_size = [0].pack("J").bytesize
        count = 256
        lru = Internal::LRUMap.new(max_size: count)
        lfu = Internal::LFUMap.new(max_size: count)
        empty_lru = ObjectSpace.memsize_of(lru)
        empty_lfu = ObjectSpace.memsize_of(lfu)
        count.times do |index|
          lru[index] = index
          lfu[index] = index
        end
        filled_lru = ObjectSpace.memsize_of(lru)
        filled_lfu = ObjectSpace.memsize_of(lfu)

        assert_equal pointer_size * (count + 5), filled_lfu - filled_lru

        (count * 4).times do |index|
          lru[count + index] = index
          lfu[count + index] = index
        end

        assert_equal filled_lru, ObjectSpace.memsize_of(lru)
        assert_equal filled_lfu, ObjectSpace.memsize_of(lfu)

        lru.clear
        lfu.clear

        assert_equal empty_lru, ObjectSpace.memsize_of(lru)
        assert_equal empty_lfu, ObjectSpace.memsize_of(lfu)

        distinct_count = 64
        frequencies = Internal::LFUMap.new(max_size: distinct_count)
        distinct_count.times { |index| frequencies[index] = index }
        shared_bucket = ObjectSpace.memsize_of(frequencies)
        distinct_count.times { |index| index.times { frequencies[index] } }

        assert_equal(
          pointer_size * 5 * (distinct_count - 1),
          ObjectSpace.memsize_of(frequencies) - shared_bucket,
        )
      end

      def test_fixnum_to_bignum_bucket_transition_preserves_order
        # The overflow test build starts new entries at FIXNUM_MAX - 1. The
        # production build runs the same policy-ordering scenario from one.
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 2)
          map[:older] = 1
          map[:newer] = 2
          3.times { map[:older] }
          2.times { map[:newer] }

          GC.start
          GC.compact if GC.respond_to?(:compact)

          assert_equal [:newer, 2], map.shift
          assert_equal [:older, 1], map.shift
        end
      end

      def test_concurrent_threads_preserve_capacity
        map = Internal::LFUMap.new(max_size: 128)
        workers = 8.times.map do |worker|
          Thread.new do
            500.times do |index|
              key = (worker * 10_000) + index
              map[key] = key
              map[key]
            end
          end
        end
        workers.each do |worker|
          assert worker.join(10), "LFU worker deadlocked"
          worker.value
        end

        assert_equal 128, map.size
        map.each { |key, value| assert_equal key, value }
      ensure
        workers&.each { it.kill.join if it.alive? }
      end

      def test_concurrent_ractor_writers
        map = Internal::ShareableLFUMap.new(max_size: 128)
        workers = 4.times.map do |worker|
          Ractor.new(map, worker) do |shared, prefix|
            300.times do |index|
              key = (prefix * 10_000) + index
              shared[key] = key
              shared[key]
            end
          end
        end
        workers.each { ractor_value(it) }

        assert_equal 128, map.size
        map.each { |key, value| assert_equal key, value }
      end

      def test_randomized_differential_against_scan_reference
        MAP_CLASSES.each do |klass|
          12.times do |seed|
            random = Random.new(seed)
            map = klass.new(max_size: 7)
            model = Helpers::BoundedMapReference.new(:lfu, max_size: 7)

            800.times do |step|
              key = [nil, false, *(-6..6)].sample(random:)
              case random.rand(8)
              when 0, 1
                value = [nil, false, (seed * 1_000) + step].sample(random:)
                expected = model[key] = value
                actual = map[key] = value

                assert expected.eql?(actual)
              when 2

                assert model[key].eql?(map[key])

              when 3

                assert model.delete(key).eql?(map.delete(key))

              when 4
                limit = random.rand(0..10)

                assert_equal(model.max_size = limit, map.max_size = limit)
              when 5
                target = random.rand(0..10)

                assert_equal model.prune(to: target), map.prune(to: target)
              when 6

                assert model.shift.eql?(map.shift)

              when 7
                model.clear
                map.clear
              end

              assert_equal model.max_size, map.max_size
              assert_equal model.size, map.size
              assert_equal model.to_h, map.each.to_h
            end
          end
        end
      end
    end
  end
end
