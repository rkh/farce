# frozen_string_literal: true

require_relative "../../setup"

module Farce
  module Internal
    class TestRactorSharing < Test
      include Helpers::InternalTestHelpers

      def test_atom_sent_over_a_ractor_port_is_not_copied
        atom = Internal::Atom.new(1)
        worker = Ractor.new do
          received = Ractor.receive
          received.upsert(0) { |old| old + 1 }
          received.object_id
        end

        worker << atom

        assert_equal atom.object_id, ractor_value(worker)
        assert_equal 2, atom.value
      end

      def test_atom_is_mutable_from_multiple_ractors
        atom = Internal::Atom.new(0)
        workers = 4.times.map do
          Ractor.new(atom) do |shared|
            250.times { shared.update { |old| old + 1 } }
          end
        end
        workers.each { |worker| ractor_value(worker) }

        assert_equal 1_000, atom.value
      end

      def test_map_is_mutable_from_multiple_ractors
        map = Internal::Map.new({ counter: 0 })
        workers = 4.times.map do
          Ractor.new(map) do |shared|
            250.times { shared.upsert(:counter, 0) { |old| old + 1 } }
          end
        end
        workers.each { |worker| ractor_value(worker) }

        assert_equal 1_000, map[:counter]
      end

      def test_queue_connects_ractors
        queue = Internal::Queue.new(capacity: 8)
        consumer = Ractor.new(queue) do |shared|
          100.times.map { shared.pop }
        end

        100.times { |index| queue.push(index) }

        assert_equal (0...100).to_a, ractor_value(consumer)
      end

      def test_unbounded_queue_grows_from_multiple_ractors
        queue = Internal::Queue.new(capacity: nil)
        workers = 4.times.map do |worker|
          Ractor.new(queue, worker) do |shared, prefix|
            250.times { |index| shared.push((prefix * 1_000) + index) }
          end
        end
        workers.each { |worker| ractor_value(worker) }

        expected = 4.times.flat_map { |worker| 250.times.map { |index| (worker * 1_000) + index } }
        actual = expected.size.times.map { queue.pop }

        assert_equal expected.sort, actual.sort
      end

      def test_queue_can_be_cleared_from_another_ractor
        queue = Internal::Queue.new(capacity: 4)
        4.times { |value| queue.push(value) }

        worker = Ractor.new(queue) do |shared|
          shared.clear
          shared.object_id
        end

        assert_equal queue.object_id, ractor_value(worker)
        assert_equal 0, queue.size
        assert queue.wait_push(timeout: 0)
      end
    end
  end
end
