# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../../setup"
require "timeout"

module Farce
  module Unsafe
    class UnsafeBoundedRecursiveHashKey
      attr_accessor :callback

      def hash
        callback&.call
        41
      end

      def eql?(other) = equal?(other)
    end

    class UnsafeBoundedCollisionKey
      attr_accessor :callback
      attr_reader :rank

      def initialize(rank) = @rank = rank
      def hash = 43

      def eql?(other)
        callback&.call
        other.is_a?(UnsafeBoundedCollisionKey) && rank == other.rank
      end
    end

    class UnsafeBoundedBadHashKey
      def initialize(result: nil, error: nil)
        @result = result
        @error = error
      end

      def hash
        raise @error if @error
        @result
      end

      def eql?(other) = equal?(other)
    end

    class TestBoundedMaps < Test
      include Helpers::InternalTestHelpers

      MAP_CLASSES = [LRUMap, LFUMap].freeze

      def test_direct_values_capacity_and_falsey_entries
        MAP_CLASSES.each do |klass|
          mutable = []
          map = klass.new([[nil, false], [false, nil]], max_size: 2)

          refute map[nil]
          assert_nil map[false]
          assert_same mutable, map[:mutable] = mutable
          assert_same mutable, map[:mutable]
          assert_equal 2, map.size

          assert_equal 1, map.max_size = 1
          assert_equal 1, map.size
          assert_equal 0, map.max_size = 0
          assert_empty map
          assert_nil map[:discarded] = nil
          assert_empty map
        end
      end

      def test_zero_capacity_still_validates_key_hash
        MAP_CLASSES.each do |klass|
          [0, 1].each do |capacity|
            invalid = klass.new(max_size: capacity)
            raising = klass.new(max_size: capacity)

            assert_raises(TypeError) do
              invalid[UnsafeBoundedBadHashKey.new(result: Object.new)] = :value
            end
            assert_empty invalid

            error = assert_raises(RuntimeError) do
              raising[UnsafeBoundedBadHashKey.new(error: "hash failed")] = :value
            end
            assert_equal "hash failed", error.message
            assert_empty raising
          end
        end
      end

      def test_backend_guard_rejects_hash_and_eql_reentry
        MAP_CLASSES.each do |klass|
          hash_map = klass.new(max_size: 2)
          recursive = UnsafeBoundedRecursiveHashKey.new
          recursive.callback = -> { hash_map.size }

          assert_raises(ThreadError) { hash_map[recursive] = :recursive }
          assert_empty hash_map
          recursive.callback = nil

          assert_equal :value, hash_map[recursive] = :value

          eql_map = klass.new(max_size: 2)
          stored = UnsafeBoundedCollisionKey.new(1)
          eql_map[stored] = :stored
          stored.callback = -> { eql_map.size }

          assert_raises(ThreadError) do
            eql_map[UnsafeBoundedCollisionKey.new(2)] = :recursive
          end
          stored.callback = nil

          assert_equal({ stored => :stored }, eql_map.to_h)
        end
      end

      def test_store_if_absent_snapshots_mutable_string_before_loader
        MAP_CLASSES.each do |klass|
          key = +"original"
          map = klass.new(max_size: 1)

          assert_equal :loaded, map.store_if_absent(key) {
            key.replace("changed")
            :loaded
          }

          assert_equal :loaded, map["original"]
          assert_nil map["changed"]
          assert_equal "original", map.getkey("original")
          assert_predicate map.getkey("original"), :frozen?
        end
      end

      def test_same_and_different_key_loaders_can_overlap
        MAP_CLASSES.each do |klass|
          assert_loaders_overlap(klass, %i[same same])
          assert_loaders_overlap(klass, %i[first second])
        end
      end

      def test_cannot_be_shared_or_transferred_between_ractors
        MAP_CLASSES.each do |klass|
          map = klass.new(max_size: 1)

          refute_predicate map, :ractor_shareable?
          refute Ractor.shareable?(map)
          assert_raises(NoMethodError) { map.freeze }
          assert_transfer_rejected { klass.new(max_size: 1) } if Internal.native_ractors?
        end
      end

      private

      def assert_loaders_overlap(klass, keys)
        map = klass.new(max_size: 2)
        entered = Queue.new
        release = Queue.new
        workers = keys.each_with_index.map do |key, index|
          Thread.new do
            map.store_if_absent(key) do
              entered << index
              release.pop
              index
            end
          end
        end

        observed = 2.times.map { Timeout.timeout(5) { entered.pop } }

        assert_equal [0, 1], observed.sort
        2.times { release << true }

        results = workers.map { |worker| Timeout.timeout(5) { worker.value } }

        assert_equal [0, 1], results.sort
        assert_equal keys.uniq.size, map.size
      ensure
        2.times { release&.push(true) }
        workers&.each { it.kill.join if it.alive? }
      end

      def assert_transfer_rejected
        copy_receiver = Ractor.new { Ractor.receive }
        move_receiver = Ractor.new { Ractor.receive }

        assert_raises(Ractor::Error, IOError, TypeError) { copy_receiver.send(yield) }
        assert_raises(Ractor::Error, IOError, TypeError) { move_receiver.send(yield, move: true) }

        copy_receiver.send(:stop)

        assert_equal :stop, ractor_value(copy_receiver)
        copy_receiver = nil

        move_receiver.send(:stop)

        assert_equal :stop, ractor_value(move_receiver)
        move_receiver = nil
      ensure
        stop_receiver(copy_receiver)
        stop_receiver(move_receiver)
      end

      def stop_receiver(receiver)
        return unless receiver
        receiver.send(:stop)
        ractor_value(receiver)
      rescue Ractor::ClosedError
        nil
      end
    end
  end
end
