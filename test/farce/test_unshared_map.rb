# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "weakref"

module Farce
  class TestUnsharedMap < Test
    include Helpers::InternalTestHelpers
    include Helpers::WeakMapContract

    def map_classes = [Unshared::Map]

    def test_public_contract_and_retention_flags
      map = Unshared::Map.new

      assert_equal Abstract::ConcurrentMap, Unshared::Map.superclass
      refute_predicate map, :weak_keys?
      refute_predicate map, :weak_values?
      refute_predicate map, :shareable_keys?
      refute_predicate map, :shareable_values?
      refute_predicate map, :ractor_shareable?
      assert_raises(NoMethodError) { map.freeze }
    end

    def test_rejects_value_transfer_modes
      assert_raises(ArgumentError) { Unshared::Map.new(mode: :copy) }

      map = Unshared::Map.new

      assert_raises(ArgumentError) { map.store(:key, :value, mode: :copy) }
      assert_raises(ArgumentError) { map.update(:key, mode: :copy) { :value } }
    end

    def test_accepts_and_strongly_retains_mutable_keys_and_values
      map, key_reference, value_reference = Thread.new do
        key = Object.new
        value = []
        map = Unshared::Map.new({ key => value })
        [map, ::WeakRef.new(key), ::WeakRef.new(value)]
      end.value

      3.times { collect_garbage }

      assert_predicate key_reference, :weakref_alive?
      assert_predicate value_reference, :weakref_alive?
      key = key_reference.__getobj__
      value = value_reference.__getobj__

      assert_same key, map.getkey(key)
      assert_same value, map[key]
      refute_predicate key, :frozen?
      refute_predicate value, :frozen?
    end

    def test_unrelated_keys_progress_while_an_update_is_blocked
      map = Unshared::Map.new({ first: 1, second: 2 })
      entered = Thread::Queue.new
      release = Thread::Queue.new
      worker = Thread.new do
        map.update(:first) do |old|
          entered << true
          release.pop
          old + 1
        end
      end
      Timeout.timeout(5) { entered.pop }

      assert_equal 3, map.update(:second, timeout: 0) { |old| old + 1 }
      assert_equal 4, map.store(:third, 4, timeout: 0)
      assert_nil map.get(:missing, timeout: 0) { flunk "unrelated key blocked" }
    ensure
      release << true if release
      worker&.join(5) || worker&.kill
    end

    def test_bracket_read_does_not_wait_for_an_atomic_update
      map = Unshared::Map.new({ key: 1 })
      entered = Thread::Queue.new
      release = Thread::Queue.new
      worker = Thread.new do
        map.update(:key) do |old|
          entered << true
          release.pop
          old + 1
        end
      end
      Timeout.timeout(5) { entered.pop }

      assert_equal 1, Timeout.timeout(1) { map[:key] }
      assert_equal :timeout, map.get(:key, timeout: 0) { :timeout }
      release << true

      assert worker.join(5), "update did not finish"
      assert_equal 2, map[:key]
    ensure
      release << true if release
      worker&.kill if worker&.alive?
    end

    def test_clear_invalidates_an_inflight_update
      map = Unshared::Map.new({ key: 1 })
      entered = Thread::Queue.new
      release = Thread::Queue.new
      worker = Thread.new do
        map.update(:key) do |old|
          entered << true
          release.pop
          old + 1
        end
      end
      Timeout.timeout(5) { entered.pop }
      map.clear
      map[:key] = 9
      release << true

      assert worker.join(5), "retired update did not finish"
      assert_nil worker.value
      assert_equal 9, map[:key]
      assert_equal 1, map.size
    ensure
      release << true if release
      worker&.kill if worker&.alive?
    end

    def test_delete_releases_the_entry_and_allows_reinsertion
      key = Object.new
      value = Object.new
      map = Unshared::Map.new({ key => value })

      assert_same value, map.delete(key)
      refute map.key?(key)
      map[key] = :replacement

      assert_equal :replacement, map[key]
      assert_equal 1, map.size
    end

    private

    def collect_garbage
      RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
    end
  end
end
