# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "weakref"

module Farce
  class TestStrictWeakCache < Test
    include Helpers::InternalTestHelpers

    class Key
      attr_reader :value

      def initialize(value) = @value = value
      def hash = 0
      def eql?(other) = other.is_a?(Key) && value == other.value
    end

    def test_empty_cache_is_shareable_and_unfrozen
      cache = Strict::WeakCache.new

      assert Ractor.shareable?(cache)
      refute_predicate cache, :frozen?
      refute_predicate cache, :compare_by_identity?
      assert_raises(KeyError) { cache.fetch(:missing) }
    end

    def test_initial_mapping_accepts_hashes_maps_and_pairs
      value = Object.new.freeze
      [{ key: value }, Strict::Map.new({ key: value }), [[:key, value]], [[:key, value]].each].each do |entries|
        cache = Strict::WeakCache.new(entries)

        assert_same value, cache.fetch(:key)
        assert_same value, cache.get(:key) { flunk "recomputed an initial entry" }
      end

      assert_equal :missing, Strict::WeakCache.new(nil).fetch(:key, :missing)
    end

    def test_invalid_constructor_arguments
      assert_raises(TypeError) { Strict::WeakCache.new(Object.new) }
      [nil, 1, :yes].each do |identity|
        assert_raises(ArgumentError) { Strict::WeakCache.new(compare_by_identity: identity) }
      end
      assert_raises(ArgumentError) { Strict::WeakCache.new(mode: :copy) }
    end

    def test_get_generates_once_without_arguments
      cache = Strict::WeakCache.new
      value = Object.new.freeze
      calls = []

      assert_same(value, cache.get(:key) do |*arguments|
        calls << arguments
        value
      end)
      assert_same value, cache.get(:key) { flunk "recomputed a live entry" }
      assert_same value, cache.fetch(:key)
      assert_equal [[]], calls
    end

    def test_store_if_absent_is_an_alias_for_get
      cache = Strict::WeakCache.new

      assert_equal :value, cache.store_if_absent(:key) { :value }
      assert_equal :value, cache.get(:key) { flunk }
      assert_equal :value, cache.store_if_absent(:key) { flunk }
    end

    def test_get_requires_a_block_even_for_present_keys
      cache = Strict::WeakCache.new({ present: 42 })
      %i[get store_if_absent].each do |method|
        assert_raises(LocalJumpError) { cache.public_send(method, :present) }
        assert_raises(LocalJumpError) { cache.public_send(method, :missing) }
      end
    end

    def test_nil_and_false_are_cached
      cache = Strict::WeakCache.new

      assert_nil cache.get(:nil) { nil }
      assert_nil cache.get(:nil) { flunk "recomputed nil" }
      assert_nil cache.fetch(:nil, :default)
      assert_nil cache.fetch(:nil) { flunk }
      assert_same false, cache.get(:false_value) { false }
      assert_same false, cache.get(:false_value) { flunk "recomputed false" }
      assert_same false, cache.fetch(:false_value, :default)
      assert_same false, cache.fetch(:false_value) { flunk }
    end

    def test_immediate_keys_work_with_both_comparison_modes
      [false, true].each do |identity|
        cache = Strict::WeakCache.new(compare_by_identity: identity)
        [nil, false, true, :key, 42, 1.5].each_with_index do |key, index|
          assert_equal index, cache.get(key) { index }
          assert_equal index, cache.get(key) { flunk "recomputed an immediate key" }
          assert_equal index, cache.fetch(key)
        end
      end
    end

    def test_fetch_defaults_and_blocks_do_not_populate_the_cache
      cache = Strict::WeakCache.new
      fallback = Object.new

      assert_same fallback, cache.fetch(:missing, fallback)
      assert_nil cache.fetch(:missing, nil)
      assert_equal :missing, cache.fetch(:missing) { |key| key }
      assert_same fallback, cache.fetch(:missing) { fallback }
      assert_raises(KeyError) { cache.fetch(:missing) }
      assert_equal :stored, cache.get(:missing) { :stored }
    end

    def test_fetch_block_supersedes_default_and_warns
      cache = Strict::WeakCache.new({ present: 42 })
      result = nil

      assert_output(nil, /block supersedes default value argument/) do
        result = cache.fetch(:missing, :default) { |key| key } # rubocop:disable Lint/UselessDefaultValueArgument
      end
      assert_equal :missing, result
      assert_output(nil, /block supersedes default value argument/) do
        result = cache.fetch(:present, :default) { flunk } # rubocop:disable Lint/UselessDefaultValueArgument
      end
      assert_equal 42, result
    end

    def test_fetch_key_error_identifies_the_key_and_cache
      cache = Strict::WeakCache.new
      key = "missing"
      error = assert_raises(KeyError) { cache.fetch(key) }

      assert_equal "key not found: #{key.inspect}", error.message
      assert_same key, error.key
      assert_same cache, error.receiver
      assert_raises(ArgumentError) { cache.fetch }
      assert_raises(ArgumentError) { cache.fetch(:key, :one, :two) }
    end

    def test_equal_keys_share_entries_and_collisions_remain_separate
      cache = Strict::WeakCache.new
      first = Key.new(:first).freeze
      equal = Key.new(:first).freeze
      second = Key.new(:second).freeze

      refute_predicate cache, :compare_by_identity?
      assert_equal :first, cache.get(first) { :first }
      assert_equal :first, cache.get(equal) { flunk }
      assert_equal :second, cache.get(second) { :second }
      assert_equal :first, cache.fetch(equal)
      assert_equal :second, cache.fetch(second)
    end

    def test_identity_keys_remain_separate
      first = String.new("key").freeze
      equal = String.new("key").freeze
      cache = Strict::WeakCache.new({ first => :first }, compare_by_identity: true)

      assert_predicate cache, :compare_by_identity?
      assert_equal :first, cache.get(first) { flunk }
      assert_equal :missing, cache.fetch(equal, :missing)
      assert_equal :second, cache.get(equal) { :second }
      assert_equal :first, cache.fetch(first)
      assert_equal :second, cache.fetch(equal)
    end

    def test_mutable_string_keys_are_copied_for_equality_comparison
      cache = Strict::WeakCache.new
      key = String.new("key")

      assert_equal :value, cache.get(key) { :value }
      refute_predicate key, :frozen?
      key.replace("changed")

      assert_equal :value, cache.fetch(String.new("key"))
      assert_equal :value, cache.get(String.new("key")) { flunk }
      assert_equal :missing, cache.fetch(key, :missing)
    end

    def test_identity_comparison_rejects_mutable_string_keys
      return unless Internal.native_ractors?

      cache = Strict::WeakCache.new(compare_by_identity: true)
      key = String.new("key")

      assert_raises(Ractor::IsolationError) { cache.get(key) { flunk } }
      assert_raises(Ractor::IsolationError) { cache.fetch(key) }
    end

    def test_unshareable_initial_entries_are_rejected
      value = Unshared::Queue.new

      assert_raises(Ractor::IsolationError) { Strict::WeakCache.new({ key: value }) }
      assert_raises(Ractor::IsolationError) { Strict::WeakCache.new({ value => :value }) }
    end

    def test_unshareable_results_are_not_cached
      cache = Strict::WeakCache.new

      assert_raises(Ractor::IsolationError) { cache.get(:key) { Unshared::Queue.new } }
      assert_raises(KeyError) { cache.fetch(:key) }
      assert_equal :recovered, cache.get(:key) { :recovered }
    end

    def test_warm_local_entries_do_not_bypass_key_validation
      return unless Internal.native_ractors?

      key = Key.new(:key).freeze
      mutable_key = key.dup
      cache = Strict::WeakCache.new
      cache.get(key) { :value }

      assert_raises(Ractor::IsolationError) { cache.get(mutable_key) { flunk } }
      assert_raises(Ractor::IsolationError) { cache.fetch(mutable_key) }
    end

    def test_failed_generation_can_be_retried
      cache = Strict::WeakCache.new

      error = assert_raises(RuntimeError) { cache.get(:key) { raise "generation failed" } }

      assert_equal "generation failed", error.message
      assert_raises(KeyError) { cache.fetch(:key) }
      assert_equal :recovered, cache.get(:key) { :recovered }
    end

    def test_nonlocal_exits_do_not_cache_a_value_or_leave_a_claim
      cache = Strict::WeakCache.new

      assert_equal :aborted, cache.get(:key) { break :aborted }
      assert_equal :aborted, catch(:abort) { cache.get(:key) { throw :abort, :aborted } }
      assert_raises(KeyError) { cache.fetch(:key) }
      assert_equal :recovered, cache.get(:key) { :recovered }
    end

    def test_recursive_generation_releases_the_key
      cache = Strict::WeakCache.new

      assert_raises(ThreadError) { cache.get(:key) { cache.get(:key) { :recursive } } }
      assert_equal :recovered, cache.get(:key) { :recovered }
      assert_equal :other, cache.get(:outer) { cache.get(:inner) { :other } }
    end

    def test_threads_generate_a_shared_value_once
      cache = Strict::WeakCache.new
      ready = Thread::Queue.new
      start = Thread::Queue.new
      calls = Thread::Queue.new
      workers = 8.times.map do
        Thread.new do
          ready << true
          start.pop
          cache.get(:key) do
            calls << true
            Object.new.freeze
          end
        end
      end
      8.times { ready.pop }
      8.times { start << true }
      values = workers.map(&:value)

      assert_equal 1, calls.size
      values.each { assert_same values.first, it }

      assert_same values.first, cache.fetch(:key)
    ensure
      workers&.each { it.kill if it.alive? }
      workers&.each(&:join)
    end

    def test_ractors_generate_a_shared_value_once
      cache = Strict::WeakCache.new
      ready = Queue.new
      start = Queue.new
      calls = Queue.new
      workers = 4.times.map do
        Ractor.new(cache, ready, start, calls) do |shared, entered, release, invoked|
          entered.push(:ready)
          raise "test start timed out" unless release.pop(timeout: 5)
          shared.get(:key) do
            invoked.push(:called)
            Object.new.freeze
          end
        end
      end
      begin
        4.times { assert_equal :ready, ready.pop(timeout: 5) }
      ensure
        4.times { start.push(:start) }
      end
      values = workers.map { ractor_value(it) }

      assert_equal 1, calls.size
      values.each { assert_same values.first, it }

      assert_same values.first, cache.fetch(:key)
    end

    def test_fibers_wait_for_generation_while_unrelated_keys_progress
      return unless Internal.native_ractors?

      cache = Strict::WeakCache.new
      ready = Queue.new
      release = Queue.new
      events = []
      Fiber.set_scheduler(Helpers::QueueTestScheduler.new)
      Fiber.schedule do
        value = cache.get(:key) do
          events << :generating
          2.times { ready.push(true) }
          raise "test release timed out" unless release.pop(timeout: 5)
          :value
        end
        events << [:generated, value]
      end
      Fiber.schedule do
        raise "test start timed out" unless ready.pop(timeout: 5)
        events << [:get, cache.get(:key) { flunk "generated twice" }]
      end
      Fiber.schedule do
        raise "test start timed out" unless ready.pop(timeout: 5)
        events << [:other, cache.get(:other) { :other }]
        release.push(true)
      end
      Fiber.set_scheduler(nil)

      assert_equal [:generating, %i[other other]], events.first(2)
      assert_equal [%i[generated value], %i[get value]], events.drop(2).sort
      assert_equal :value, cache.fetch(:key)
    ensure
      release&.push(true)
      Fiber.set_scheduler(nil) if Fiber.respond_to?(:scheduler) && Fiber.scheduler
    end

    def test_entries_and_identity_settings_are_visible_in_other_ractors
      key = String.new("key").freeze
      value = Object.new.freeze
      [false, true].each do |identity|
        cache = Strict::WeakCache.new({ key => value }, compare_by_identity: identity)
        worker = Ractor.new(cache, key) do |shared, stored_key|
          [shared.fetch(stored_key), shared.fetch(String.new("key").freeze, :missing),
           shared.compare_by_identity?, shared.get(:new) { :created }]
        end
        result = ractor_value(worker)

        assert_same value, result[0]
        assert_same(identity ? :missing : value, result[1])
        assert_equal identity, result[2]
        assert_equal :created, result[3]
        assert_equal :created, cache.fetch(:new)
      end
    end

    def test_freezing_prevents_get_even_for_warm_entries
      cache = Strict::WeakCache.new
      cache.get(:key) { :value }

      assert_same cache, cache.freeze
      assert_predicate cache, :frozen?
      assert_equal :value, cache.fetch(:key)
      assert_raises(FrozenError) { cache.get(:key) { flunk } }
      assert_raises(FrozenError) { cache.get(:missing) { flunk } }
    end

    def test_frozen_cache_can_fetch_from_another_ractor
      cache = Strict::WeakCache.new({ key: :value }).freeze
      worker = Ractor.new(cache) { |shared| [shared.frozen?, shared.fetch(:key), shared.fetch(:missing, :default)] }

      assert_equal [true, :value, :default], ractor_value(worker)
    end

    def test_freezing_during_generation_does_not_cache_the_result
      cache = Strict::WeakCache.new

      assert_raises(FrozenError) do
        cache.get(:key) do
          cache.freeze
          :value
        end
      end
      assert_raises(KeyError) { cache.fetch(:key) }
    end

    def test_marshal_preserves_entries_identity_shareability_and_frozen_state
      [false, true].product([false, true]).each do |identity, frozen|
        key = String.new("key").freeze
        value = Object.new.freeze
        entries = { key => value, nil_value: nil, false_value: false }
        cache = Strict::WeakCache.new(entries, compare_by_identity: identity)
        cache.freeze if frozen
        copy, restored_key, restored_value = ::Marshal.load(::Marshal.dump([cache, key, value]))

        assert_instance_of Strict::WeakCache, copy
        assert_equal identity, copy.compare_by_identity?
        assert_equal frozen, copy.frozen?
        assert Ractor.shareable?(copy)
        assert_same restored_value, copy.fetch(restored_key)
        assert_same(identity ? :missing : restored_value, copy.fetch(String.new("key").freeze, :missing))
        assert_nil copy.fetch(:nil_value)
        assert_same false, copy.fetch(:false_value)
        worker = Ractor.new(copy, restored_key) { |shared, lookup| shared.fetch(lookup) }

        assert_same restored_value, ractor_value(worker)
        if frozen
          assert_raises(FrozenError) { copy.get(:new) { flunk } }
        else
          assert_equal :new, copy.get(:new) { :new }
        end

        assert_equal :missing, cache.fetch(:new, :missing)
      end
    end

    def test_marshal_rejects_invalid_snapshots
      assert_raises(TypeError) { Strict::WeakCache.allocate.marshal_load([]) }
    end

    def test_generated_values_can_be_collected_and_regenerated
      [false, true].each do |identity|
        cache = Strict::WeakCache.new(compare_by_identity: identity)
        reference = Thread.new do
          ::WeakRef.new(cache.get(:key) { Object.new.freeze })
        end.value

        assert_collected(reference, cache)
        assert_raises(KeyError) { cache.fetch(:key) }
        assert_equal :replacement, cache.get(:key) { :replacement }
      end
    end

    def test_initial_values_can_be_collected
      cache, reference = Thread.new do
        value = Object.new.freeze
        [Strict::WeakCache.new({ key: value }), ::WeakRef.new(value)]
      end.value

      assert_collected(reference, cache)
      assert_raises(KeyError) { cache.fetch(:key) }
      assert_equal :replacement, cache.get(:key) { :replacement }
    end

    def test_equal_lookup_keys_can_be_collected_while_the_value_is_live
      key = Key.new(:key).freeze
      value = Object.new.freeze
      cache = Strict::WeakCache.new({ key => value })
      reference = Thread.new do
        lookup = Key.new(:key).freeze
        cache.get(lookup) { raise "recomputed an equal key" }
        ::WeakRef.new(lookup)
      end.value

      assert_collected(reference, cache)
      assert_same value, cache.get(Key.new(:key).freeze) { flunk }
      assert_same value, cache.fetch(key)
    end

    def test_abandoned_caches_can_be_collected_while_the_value_is_live
      value = Object.new.freeze
      reference = Thread.new do
        cache = Strict::WeakCache.new
        cache.get(:key) { value }
        ::WeakRef.new(cache)
      end.value

      assert_collected(reference, Strict::WeakCache.new)
      assert_predicate value, :frozen?
    end

    def test_live_entries_survive_gc_and_compaction
      keys = 128.times.map { "key-#{it}".freeze }
      values = 128.times.map { Object.new.freeze }
      [false, true].each do |identity|
        cache = Strict::WeakCache.new(compare_by_identity: identity)
        keys.each_with_index { |key, index| cache.get(key) { values[index] } }
        GC.start
        GC.compact if GC.respond_to?(:compact)
        keys.each_with_index do |key, index|
          assert_same values[index], cache.get(key) { flunk "lost a live value" }
          assert_same values[index], cache.fetch(key)
        end
      end
    end

    private

    def assert_collected(reference, cache)
      50.times do
        # Replace the owner Ractor's last reply before collecting its weak values.
        cache.fetch(:unrelated, nil)
        2_000.times { Object.new }
        RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
        break unless reference.weakref_alive?
        sleep 0.01
      end

      refute_predicate reference, :weakref_alive?, "cache retained the referenced object"
    end
  end
end
