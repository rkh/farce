# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "pp"

module Farce
  class TestLazyModes < Test
    include Helpers::InternalTestHelpers

    def test_defaults_to_copy_and_caches_mutable_results
      calls = Counter.new
      lazy = Lazy.new do
        calls.increment
        []
      end

      assert_equal :copy, lazy.mode
      value = lazy.value
      value << :parent

      assert_same value, lazy.value
      assert_equal 1, calls.value
      assert_equal "#<Farce::Lazy [:parent]>", lazy.inspect
      assert_equal "#<Farce::Lazy [:parent]>", lazy.pretty_inspect.chomp
    end

    def test_copy_result_is_isolated_and_cached_in_each_ractor
      return unless Internal.native_ractors?

      calls = Counter.new
      lazy = Lazy.new do
        calls.increment
        [:initial]
      end
      parent = lazy.value
      parent << :parent
      worker = Ractor.new(lazy) do |shared|
        value = shared.value
        before = value.dup
        value << :child
        [before, value, value.equal?(shared.value)]
      end

      assert_equal [[:initial], %i[initial child], true], ractor_value(worker)
      assert_equal %i[initial parent], parent
      assert_equal 1, calls.value
    end

    def test_non_main_ractor_can_compute_the_result_first
      return unless Internal.native_ractors?

      calls = Counter.new
      lazy = Lazy.new do
        calls.increment
        [:initial]
      end
      worker = Ractor.new(lazy) { |shared| shared.value << :child }

      assert_equal %i[initial child], ractor_value(worker)
      assert_equal [:initial], lazy.value
      assert_equal 1, calls.value
    end

    def test_local_mode_preserves_mutable_identity
      lazy = Lazy.new(mode: :local) { [] }
      value = lazy.value
      value << :item

      assert_equal :local, lazy.mode
      assert_same value, Thread.new { lazy.value }.value
      assert_equal [:item], lazy.value
      return unless Internal.native_ractors?

      worker = Ractor.new(lazy) do |shared|
        shared.value
      rescue Envelope::AlreadyClaimed
        :rejected
      end

      assert_equal :rejected, ractor_value(worker)
    end

    def test_move_result_is_cached_by_its_owner
      lazy = Lazy.new(mode: :move) { [] }
      result = lazy.value
      result << :owned

      assert_same result, lazy.value
      assert_equal [:owned], lazy.value
      return unless Internal.native_ractors?

      worker = Ractor.new(lazy) do |shared|
        shared.value
      rescue Envelope::AlreadyClaimed
        :rejected
      end

      assert_equal :rejected, ractor_value(worker)
    end

    def test_modes_that_prepare_shareable_results
      %i[make_shareable shareable_copy dedup].each do |mode|
        lazy = Lazy.new(mode:) { [String.new("value")] }
        result = lazy.value

        assert_equal mode, lazy.mode
        assert_equal ["value"], result
        assert Ractor.shareable?(result)
        assert_same result, lazy.value
      end
    end

    def test_proxy_mode_retains_mutable_remote_state
      return unless Internal.native_ractors?

      lazy = Lazy.new(mode: :proxy) { [] }
      value = lazy.value

      assert_operator Proxy, :===, value
      value.push(:item)

      assert_equal [:item], value.to_a
      assert_same value, lazy.value
    end

    def test_invalid_mode_fails_without_running_the_factory
      calls = Counter.new

      assert_raises(ArgumentError) do
        Lazy.new(mode: :invalid) do
          calls.increment
          []
        end
      end
      assert_equal 0, calls.value
    end

    def test_nil_false_and_shareable_results_pass_through_in_every_mode
      Farce::MODES.each do |mode|
        [nil, false, :ready].each do |result|
          calls = Counter.new
          lazy = Lazy.new(mode:) do
            calls.increment
            result
          end

          if result.nil?
            assert_nil lazy.value
            assert_nil lazy.value
          else
            assert_same result, lazy.value
            assert_same result, lazy.value
          end

          assert_equal 1, calls.value
        end
      end
    end

    def test_freezing_and_copying_keep_the_mutable_cached_result
      lazy = Lazy.new { [] }
      copy = lazy.dup
      lazy.freeze
      value = lazy.value

      assert_predicate lazy, :frozen?
      refute_predicate copy, :frozen?
      refute_predicate value, :frozen?
      assert_same value, copy.value
      value << :item

      assert_equal [:item], lazy.value
    end

    def test_user_created_envelopes_remain_wrapped
      envelope = Envelope.new([:item])
      lazy = Lazy.new(self: envelope) { self }

      assert_same envelope, lazy.value
    end

    def test_lazy_ref_caches_a_separate_mutable_copy_in_each_ractor
      return unless Internal.native_ractors?

      reference = LazyRef.new(Array)
      reference.push(:parent)
      worker = Ractor.new(reference) do |shared|
        shared.push(:child)
        shared.to_a
      end

      assert_equal [:child], ractor_value(worker)
      assert_equal [:parent], reference.to_a
    end

    def test_lazy_ref_forwards_mode_and_self_options
      reference = LazyRef.new(mode: :make_shareable, self: :ready) { [self] }
      lazy = Reference.deref(reference)

      assert_empty LazyRef.new(Array, mode: :local)
      assert_raises(ArgumentError) { LazyRef.new(Array, mode: :invalid) }
      assert_equal :make_shareable, lazy.mode
      assert_equal [:ready], reference.to_a
      assert_predicate lazy.value, :frozen? if Internal.native_ractors?
    end
  end
end
