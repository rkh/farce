# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "pp"

module Farce
  class TestUnsharedLazy < Test
    include Helpers::InternalTestHelpers

    def test_retains_mutable_factory_state_and_result_identity
      calls = []
      result = []
      lazy = Unshared::Lazy.new do
        calls << :called
        result
      end

      assert_kind_of Abstract::Lazy, lazy
      refute_predicate lazy, :ractor_shareable?
      assert_empty calls
      assert_same result, lazy.value
      assert_same result, lazy.value
      assert_equal [:called], calls
      refute Ractor.shareable?(lazy)
    end

    def test_keeps_original_receiver_without_self_option
      lazy = Unshared::Lazy.new { object_id }

      assert_equal object_id, lazy.value
    end

    def test_accepts_mutable_bound_receiver
      receiver = []
      lazy = Unshared::Lazy.new(self: receiver) { self << :item }

      assert_same receiver, lazy.value
      assert_equal [:item], receiver
    end

    def test_accepts_class_and_proc_factories
      result = []

      assert_empty Unshared::Lazy.new(Array).value
      assert_same result, Unshared::Lazy.new(-> { result }).value
    end

    def test_caches_nil_and_false
      [nil, false].each do |result|
        calls = 0
        lazy = Unshared::Lazy.new do
          calls += 1
          result
        end

        if result.nil?
          assert_nil lazy.value
          assert_nil lazy.value
        else
          assert_same result, lazy.value
          assert_same result, lazy.value
        end

        assert_equal 1, calls
      end
    end

    def test_retries_failed_factory_and_computes_once_under_contention
      calls = 0
      result = []
      lazy = Unshared::Lazy.new do
        calls += 1
        raise "not ready" if calls == 1

        Thread.pass
        result
      end

      assert_raises(RuntimeError) { lazy.value }
      workers = 8.times.map { Thread.new { lazy.value } }
      workers.each { assert_same result, it.value }

      assert_equal 2, calls
    ensure
      workers&.each { it.kill.join }
    end

    def test_copies_share_evaluation
      calls = []
      lazy = Unshared::Lazy.new do
        calls << :called
        []
      end
      duplicate = lazy.dup
      clone = lazy.clone

      assert_same lazy.value, duplicate.value
      assert_same lazy.value, clone.value
      assert_equal [:called], calls
    end

    def test_delegates_and_displays_without_eager_computation
      calls = []
      lazy = Unshared::Lazy.new do
        calls << :called
        []
      end
      lazy.inspect
      lazy.pretty_inspect

      assert_empty calls
      assert_respond_to lazy, :push
      lazy.push(:item)

      assert_equal [:item], lazy.value
      assert_equal [:called], calls
    end

    def test_cannot_be_copied_or_moved_to_another_ractor
      return unless Internal.native_ractors?

      lazy = Unshared::Lazy.new { [] }

      worker = Ractor.new { loop { break if Ractor.receive == :done } }

      assert_raises(Ractor::Error, TypeError) { worker.send(lazy) }
      assert_raises(Ractor::Error, TypeError) { worker.send(lazy, move: true) }
    ensure
      worker&.send(:done)
      ractor_value(worker) if worker
    end

    def test_rejects_modes_and_conflicting_factories
      assert_raises(ArgumentError) { Unshared::Lazy.new(Array, mode: :copy) }
      assert_raises(ArgumentError) { Unshared::Lazy.new(mode: :copy) { [] } }
      assert_raises(ArgumentError) { Unshared::Lazy.new(Array) { [] } }
    end
  end
end
