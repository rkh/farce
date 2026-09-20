# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"

module Farce
  module Internal
    class TestWeakMapPerKey < Test
      MAPS = [WeakKeyMap, WeakValueMap, WeakMap, UnsharedWeakKeyMap, UnsharedWeakValueMap, UnsharedWeakMap].freeze

      def test_unrelated_keys_progress_during_update_and_creation
        MAPS.each do |type|
          %i[update store_if_absent].each do |method|
            map = type.new({ other: 1 })
            entered = Thread::Queue.new
            release = Thread::Queue.new
            worker = Thread.new do
              map.public_send(method, :busy) do
                entered << true
                release.pop
                2
              end
            end
            begin
              Timeout.timeout(5) { entered.pop }

              assert_nil map.get(:busy, timeout: 0)
              assert_equal :blocked, map.store(:busy, 3, timeout: 0) { :blocked }
              assert_equal :blocked, Timeout.timeout(5) {
                map.wait_until_changed(:busy, nil, timeout: 0) { :blocked }
              }
              assert_equal 4, map.store_if_absent(:new, timeout: 0) { 4 }, type.name
              assert_equal 2, map.update(:other, timeout: 0) { it + 1 }, type.name
              assert_equal 4, map.get(:new, timeout: 0)
              assert_equal 2, Timeout.timeout(5) { map.delete(:other) }
            ensure
              release << true
              worker.join(5) || worker.kill
            end

            assert_equal 2, worker.value
            assert_equal 2, map[:busy]
          end
        end
      end

      def test_nested_updates_on_different_keys_are_allowed
        MAPS.each do |type|
          map = type.new({ a: 1, b: 2 })

          assert_equal(4, map.update(:a) { |old| old + map.update(:b) { it + 1 } })
          assert_equal({ a: 4, b: 3 }, map.each.to_h)
        end
      end

      def test_interrupting_an_update_preserves_other_reservations
        MAPS.each do |type|
          map = type.new({ a: 1, b: 2 })
          entered = Thread::Queue.new
          release = Thread::Queue.new
          workers = []
          begin
            %i[a b].each do |key|
              workers << Thread.new do
                map.update(key) do |old|
                  entered << true
                  release.pop
                  old + 1
                end
              end
              Timeout.timeout(5) { entered.pop }
            end
            workers.first.kill
            Timeout.timeout(5) { workers.first.join }

            assert_equal 4, map.update(:a, timeout: 0) { 4 }
            assert_equal :busy, map.store(:b, 9, timeout: 0) { :busy }
            release << true

            assert_equal 3, Timeout.timeout(5) { workers.last.value }
            assert_equal({ a: 4, b: 3 }, map.each.to_h)
          ensure
            workers.each { it.kill if it.alive? }
            workers.each(&:join)
          end
        end
      end

      def test_equal_keys_share_a_reservation_and_identity_keys_do_not
        MAPS.each do |type|
          first = String.new("key").freeze
          second = String.new("key").freeze
          map = type.new({ first => 1 })

          assert_raises(ThreadError) { map.update(first) { map.update(second) { 2 } } }
          identity = type.new(compare_keys_by_identity: true)
          identity[first] = 1

          assert_equal(3, identity.update(first) { 1 + identity.store_if_absent(second) { 2 } })
          assert_equal 2, identity.size
        end
      end

      def test_clear_invalidates_all_live_reservations
        MAPS.each do |type|
          map = type.new({ a: 1 })
          result = map.update(:a) do
            map.store_if_absent(:b) do
              map.clear
              map[:a] = 7
              2
            end
            3
          end

          assert_nil result
          assert_equal({ a: 7 }, map.each.to_h)
        end
      end

      def test_exception_releases_only_its_own_reservation
        MAPS.each do |type|
          map = type.new({ a: 1 })
          result = map.update(:a) do |old|
            assert_raises(RuntimeError) { map.update(:b) { raise "failure" } }
            assert_raises(ThreadError) { map.update(:a) { 9 } }
            old + 1
          end

          assert_equal 2, result
          assert_equal 3, map.store_if_absent(:b) { 3 }
        end
      end

      def test_live_reservations_survive_gc_and_table_growth
        MAPS.each do |type|
          map = type.new
          key = String.new("outer").freeze
          equal_key = String.new("outer").freeze
          value = [1].freeze
          map[key] = value
          result = map.update(equal_key) do |current|
            128.times { |index| map[index] = index }
            GC.start
            GC.compact if GC.respond_to?(:compact)

            assert_same value, current
            assert_raises(ThreadError) { map.update(equal_key) { 9 } }
            [2].freeze
          end

          assert_equal [2], result
          assert_same result, map[key]
          assert_same key, map.getkey(equal_key)
        end
      end

      def test_another_ractor_can_update_a_different_key
        [WeakKeyMap, WeakValueMap, WeakMap].each do |type|
          map = type.new({ a: 1, b: 2 })
          entered = Farce::Queue.new
          release = Farce::Queue.new
          worker = Ractor.new(map, entered, release) do |shared, ready, resume|
            shared.update(:a) do |old|
              ready.push(true)
              resume.pop
              old + 1
            end
          end
          begin
            Timeout.timeout(5) { entered.pop }

            assert_equal 3, map.update(:b, timeout: 0) { it + 1 }
            assert_equal :busy, map.store(:a, 9, timeout: 0) { :busy }
          ensure
            release.push(true)
            result = worker.respond_to?(:value) ? worker.value : worker.take
          end

          assert_equal 2, result
        end
      end
    end
  end
end
