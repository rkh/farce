# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMutableModes < Test
    include Helpers::InternalTestHelpers

    def test_containers_apply_the_default_mutable_mode
      source = +"original"
      atom = Atom.new(source, mode: :mutable)
      map = Map.new({ key: source }, mode: :mutable)
      vector = Vector.new([source], mode: :mutable)
      queue = Queue.new(mode: :mutable)
      queue.push(source)
      results = [atom.value, map[:key], vector[0], queue.pop]

      results.each do |value|
        assert_operator Mutable, :===, value if Internal.native_ractors?
        assert_same source, value unless Internal.native_ractors?

        assert_same value, value.replace("changed")
        assert_equal "changed", value.to_s
      end
      assert_same results[0], atom.value
      assert_same results[1], map[:key]
      assert_same results[2], vector[0]
      assert_equal "original", source if Internal.native_ractors?

      refute_predicate source, :frozen?
    end

    def test_containers_accept_a_mutable_mode_override
      atom = Atom.new(mode: :raise)
      map = Map.new(mode: :raise)
      vector = Vector.new(mode: :raise)
      queue = Queue.new(mode: :raise)
      source = +"value"
      atom.store(source, mode: :mutable)
      map.store(:key, source, mode: :mutable)
      vector.push(source, mode: :mutable)
      queue.push(source, mode: :mutable)

      [atom.value, map[:key], vector[0], queue.pop].each do |value|
        assert_operator Mutable, :===, value if Internal.native_ractors?
        assert_same source, value unless Internal.native_ractors?

        assert_equal "value", value.to_s
      end
      [atom, map, vector, queue].each do |container|
        assert_equal :raise, container.mode
      end
    end

    def test_lazy_caches_one_mutable_wrapper
      calls = Counter.new
      lazy = Lazy.new(mode: :mutable) do
        calls.increment
        +"value"
      end
      value = lazy.value
      value.replace("changed")

      assert_operator Mutable, :===, value if Internal.native_ractors?

      assert_same value, lazy.value
      assert_equal "changed", lazy.value.to_s
      assert_equal 1, calls.value
    end

    def test_queue_transfers_a_wrapper_that_shares_mutations_across_ractors
      source = +"original"
      queue = Queue.new(mode: :mutable)
      queue.push(source)
      worker = Ractor.new(queue) do |shared|
        value = shared.pop
        value << " updated"
        shared.push(value)
        Ractor.shareable?(value)
      end

      assert ractor_value(worker)
      value = queue.pop

      assert_operator Mutable, :===, value if Internal.native_ractors?

      assert_equal "original updated", value.to_s
      assert_equal "original", source if Internal.native_ractors?
      value << " again"

      assert_equal "original updated again", value.to_s
    end
  end
end
