# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby"

require_relative "../../setup"

module Farce
  module Internal
    class TestNativeGC < Test
      include Helpers::InternalTestHelpers

      def test_old_maps_retain_new_keys_and_values_after_minor_collection
        types = [Map, UnsharedMap, TreeMap, UnsafeTreeMap, ShareableTreeMap,
                 LRUMap, ShareableLRUMap, LFUMap, ShareableLFUMap]
        types.each do |type|
          map = type.name.include?("LRU") || type.name.include?("LFU") ? type.new(max_size: 4) : type.new
          promote
          write_young do |value|
            map[String.new("key").freeze] = value
          end
          collect_young

          assert_equal "young value", map["key"], type.name
          assert_equal ["key"], map.each.to_h.keys, type.name
        end
      end

      def test_weak_maps_retain_only_their_strong_edges_after_minor_collection
        return unless Internal.const_defined?(:NATIVE_WEAK_MAPS, false)

        weak_key_map = WeakKeyMap.new
        weak_value_map = WeakValueMap.new
        promote
        write_young do |value|
          weak_key_map[:key] = value
          weak_value_map[String.new("key").freeze] = 1
        end
        collect_young

        assert_equal "young value", weak_key_map[:key]
        assert_equal ["key"], weak_value_map.keys
      end

      def test_old_atoms_vectors_and_queues_retain_replacements_after_minor_collection
        atom = Atom.new
        vector = Vector.new
        queues = [Queue.new, UnsharedQueue.new]
        promote
        write_young do |value|
          atom.value = value
          vector.push(value)
          queues.each do |queue|
            queue.push(value)
          end
        end
        collect_young

        assert_equal "young value", atom.value
        assert_equal ["young value"], vector.snapshot
        queues.each { assert_equal "young value", it.pop }
      end

      def test_old_priority_queues_retain_new_priorities_and_values_after_minor_collection
        [PriorityQueue, UnsharedPriorityQueue].each do |type|
          queue = type.new
          promote
          write_young do |value|
            queue.push(String.new("priority").freeze, value)
          end
          collect_young

          assert_equal "priority", queue.peek_priority, type.name
          assert_equal "young value", queue.pop, type.name
        end
      end

      def test_transaction_buffer_transfers_retain_new_references_after_minor_collection
        map = Farce::Strict::Map.new
        tree = Farce::Strict::TreeMap.new
        vector = Farce::Strict::Vector.new
        atom = Farce::Strict::Atom.new
        promote
        write_young do
          Farce.transaction do |tx|
            # Collect while the private copies are alive, then add young values.
            views = [tx[map], tx[tree], tx[vector], tx[atom]]
            promote
            value = String.new("young value").freeze
            views[0][:key] = value
            views[1][1] = value
            views[2].push(value)
            views[3].value = value
          end
        end
        collect_young

        assert_equal "young value", map[:key]
        assert_equal "young value", tree[1]
        assert_equal ["young value"], vector.to_a
        assert_equal "young value", atom.value
      end

      private

      def promote
        3.times { GC.start }
      end

      def collect_young
        2.times { GC.start(full_mark: false, immediate_sweep: true) }
      end

      # The exited thread leaves no caller-owned strong reference to the value.
      def write_young
        Thread.new do
          yield String.new("young value").freeze
          nil
        end.value
      end
    end
  end
end
