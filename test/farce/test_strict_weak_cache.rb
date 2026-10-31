# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# rubocop:disable Style/SingleArgumentDig

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

    def test_public_instance_methods_are_a_subset_of_weak_value_map
      cache = Strict::WeakCache.new

      refute_respond_to cache, :get
      assert_empty Strict::WeakCache.public_instance_methods - Strict::WeakValueMap.public_instance_methods
    end

    def test_create_selects_the_platform_cache_and_forwards_arguments
      expected_class = Internal.native_weak_maps? ? Strict::WeakValueMap : Strict::WeakCache
      empty = Strict::WeakCache.create

      assert_instance_of expected_class, empty
      assert_raises(KeyError) { empty.fetch(:missing) }

      first = String.new("key").freeze
      equal = String.new("key").freeze
      [false, true].each do |identity|
        cache = Strict::WeakCache.create({ first => :first }, compare_by_identity: identity)

        assert_instance_of expected_class, cache
        assert Ractor.shareable?(cache)
        assert_equal identity, cache.compare_by_identity?
        assert_equal :first, cache.fetch(first)
        assert_equal(identity ? :second : :first, cache.store_if_absent(equal) { :second })
        assert_equal :first, cache.fetch(first)
      end
    end

    def test_initial_mapping_accepts_hashes_maps_and_pairs
      value = Object.new.freeze
      [{ key: value }, Strict::Map.new({ key: value }), [[:key, value]], [[:key, value]].each].each do |entries|
        cache = Strict::WeakCache.new(entries)

        assert_same value, cache.fetch(:key)
        assert_same value, cache.store_if_absent(:key) { flunk "recomputed an initial entry" }
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

    def test_store_if_absent_generates_once_without_arguments
      %i[store_if_absent compute_if_absent].each do |method|
        cache = Strict::WeakCache.new
        value = Object.new.freeze
        calls = []

        assert_same(value, cache.public_send(method, :key) do |*arguments|
          calls << arguments
          value
        end)
        assert_same value, cache.public_send(method, :key) { flunk "recomputed a live entry" }
        assert_same value, cache.fetch(:key)
        assert_equal [[]], calls
      end
    end

    def test_compute_if_absent_is_an_alias_for_store_if_absent
      cache = Strict::WeakCache.new

      assert_equal :store_if_absent, cache.method(:store_if_absent).original_name
      assert_equal cache.method(:store_if_absent), cache.method(:compute_if_absent)
      assert_equal :value, cache.store_if_absent(:key) { :value }
      assert_equal :value, cache.store_if_absent(:key) { flunk }
      assert_equal :value, cache.compute_if_absent(:key) { flunk }
    end

    def test_store_if_absent_requires_a_block_even_for_present_keys
      cache = Strict::WeakCache.new({ present: 42 })
      %i[store_if_absent compute_if_absent].each do |method|
        assert_raises(LocalJumpError) { cache.public_send(method, :present) }
        assert_raises(LocalJumpError) { cache.public_send(method, :missing) }
      end
    end

    def test_nil_and_false_are_cached
      cache = Strict::WeakCache.new

      assert_nil cache.store_if_absent(:nil) { nil }
      assert_nil cache.store_if_absent(:nil) { flunk "recomputed nil" }
      assert_nil cache.fetch(:nil, :default)
      assert_nil cache.fetch(:nil) { flunk }
      assert_nil cache.compute_if_absent(:nil) { flunk "recomputed nil" }
      assert_same false, cache.store_if_absent(:false_value) { false }
      assert_same false, cache.store_if_absent(:false_value) { flunk "recomputed false" }
      assert_same false, cache.fetch(:false_value, :default)
      assert_same false, cache.fetch(:false_value) { flunk }
      assert_same false, cache.compute_if_absent(:false_value) { flunk "recomputed false" }
    end

    def test_values_at_preserves_order_duplicates_and_missing_entries
      [false, true].each do |identity|
        value = Object.new.freeze
        entries = { value:, nil_value: nil, false_value: false }
        cache = Strict::WeakCache.new(entries, compare_by_identity: identity).freeze

        assert_equal [], cache.values_at
        2.times do
          result = cache.values_at(:false_value, :value, :missing, :nil_value, :value)

          assert_equal [false, value, nil, nil, value], result
        end
        assert_raises(KeyError) { cache.fetch(:missing) }
      end
    end

    def test_fetch_values_preserves_order_and_calls_the_block_only_for_missing_keys
      [false, true].each do |identity|
        value = Object.new.freeze
        entries = { value:, nil_value: nil, false_value: false }
        cache = Strict::WeakCache.new(entries, compare_by_identity: identity).freeze
        missing = String.new("missing").freeze
        fallback = Object.new
        calls = []

        assert_equal([], cache.fetch_values { flunk "no keys requested" })
        2.times do
          assert_equal [false, value, nil, value], cache.fetch_values(:false_value, :value, :nil_value, :value)
        end
        result = cache.fetch_values(:value, missing, :nil_value, :false_value, missing) do |key|
          calls << key
          fallback
        end

        assert_equal [value, fallback, nil, false, fallback], result
        assert_equal [missing, missing], calls
        assert_same missing, calls.first
        error = assert_raises(KeyError) { cache.fetch_values(:value, missing) }

        assert_same cache, error.receiver
        assert_same missing, error.key
        refute cache.key?(missing)
      end
    end

    def test_assoc_returns_the_lookup_key_and_handles_nil_and_false_values
      first = Key.new(:first).freeze
      equal = Key.new(:first).freeze
      value = Object.new.freeze
      [false, true].each do |identity|
        entries = { first => value, nil_value: nil, false_value: false }
        cache = Strict::WeakCache.new(entries, compare_by_identity: identity)

        2.times do
          pair = cache.assoc(first)

          assert_same first, pair.first
          assert_same value, pair.last
          assert_equal [:nil_value, nil], cache.assoc(:nil_value)
          assert_equal [:false_value, false], cache.assoc(:false_value)
          assert_nil cache.assoc(:missing)
          if identity
            assert_nil cache.assoc(equal)
          else
            pair = cache.assoc(equal)

            assert_same equal, pair.first
            assert_same value, pair.last
          end
        end

        refute cache.key?(:missing)
      end
    end

    def test_bulk_lookups_and_assoc_use_the_configured_key_comparison
      first = Key.new(:first).freeze
      equal = Key.new(:first).freeze
      [false, true].each do |identity|
        cache = Strict::WeakCache.new({ first => :value }, compare_by_identity: identity)

        assert_equal identity, cache.compare_keys_by_identity?
        assert_equal cache.compare_by_identity?, cache.compare_keys_by_identity?
        assert_equal [identity ? nil : :value, :value], cache.values_at(equal, first)
        assert_equal [identity ? :missing : :value, :value], cache.fetch_values(equal, first) { :missing }
      end
    end

    def test_put_if_absent_preserves_live_entries_and_returns_nil_for_insertions
      [false, true].each do |identity|
        value = Object.new.freeze
        cache = Strict::WeakCache.new({ value:, nil_value: nil, false_value: false }, compare_by_identity: identity)

        2.times do
          assert_same value, cache.put_if_absent(:value, :unused)
          assert_nil cache.put_if_absent(:nil_value, :unused)
          assert_same false, cache.put_if_absent(:false_value, :unused)
        end
        assert_nil cache.fetch(:nil_value)
        assert_same false, cache.fetch(:false_value)
        assert_nil cache.put_if_absent(:missing, value)
        assert_same value, cache.fetch(:missing)
        assert_nil cache.put_if_absent(:new_nil, nil)
        assert_nil cache.fetch(:new_nil)
        assert_nil cache.put_if_absent(:new_false, false)
        assert_same false, cache.fetch(:new_false)
      end
    end

    def test_put_if_absent_uses_the_configured_key_comparison
      first = Key.new(:first).freeze
      equal = Key.new(:first).freeze
      [false, true].each do |identity|
        cache = Strict::WeakCache.new({ first => :first }, compare_by_identity: identity)
        previous = cache.put_if_absent(equal, :second)

        if identity
          assert_nil previous
        else
          assert_equal :first, previous
        end

        assert_equal :first, cache.fetch(first)
        assert_equal(identity ? :second : :first, cache.fetch(equal))
      end
    end

    def test_put_if_absent_validates_only_inserted_values_and_obeys_freezing
      cache = Strict::WeakCache.new({ present: :value })
      unshareable = Unshared::Queue.new

      assert_equal :value, cache.put_if_absent(:present, unshareable)
      assert_raises(Ractor::IsolationError) { cache.put_if_absent(:missing, unshareable) }
      assert_raises(Ractor::IsolationError) { cache.put_if_absent(unshareable, :value) }
      refute cache.key?(:missing)
      assert_equal :created, cache.compute_if_absent(:missing) { :created }
      cache.freeze

      assert_raises(FrozenError) { cache.put_if_absent(:present, :unused) }
      assert_raises(FrozenError) { cache.put_if_absent(:new, :value) }
      assert_raises(FrozenError) { cache.compute_if_absent(:present) { flunk } }
      assert_raises(FrozenError) { cache.compute_if_absent(:new) { flunk } }
    end

    def test_concurrent_put_if_absent_has_one_successful_insertion
      cache = Strict::WeakCache.new
      ready = Thread::Queue.new
      start = Thread::Queue.new
      workers = 8.times.map do |index|
        Thread.new do
          ready << true
          start.pop
          [index, cache.put_if_absent(:key, index)]
        end
      end
      workers.size.times { ready.pop }
      workers.size.times { start << true }
      results = workers.map(&:value)
      inserted = results.select { |_, previous| previous.nil? }

      assert_equal 1, inserted.size
      winner = inserted.first.first

      assert_equal winner, cache.fetch(:key)
      results.each { |index, previous| assert_equal winner, previous unless index == winner }
    ensure
      workers&.each { |worker| worker.kill if worker.alive? }
      workers&.each(&:join)
    end

    def test_map_predicates_describe_strong_shareable_keys_and_weak_shareable_values
      cache = Strict::WeakCache.new
      map = Strict::WeakValueMap.new

      %i[shareable_keys? shareable_values? weak_keys? weak_values?].each do |method|
        assert_equal map.public_send(method), cache.public_send(method)
      end
    end

    def test_bracket_lookup_returns_live_values_without_storing_missing_entries
      [false, true].each do |identity|
        value = Object.new.freeze
        cache = Strict::WeakCache.new({ value:, nil_value: nil, false_value: false }, compare_by_identity: identity)

        2.times do
          assert_same value, cache[:value]
          assert_nil cache[:nil_value]
          assert_same false, cache[:false_value]
          assert_nil cache[:missing]
        end
        assert_raises(KeyError) { cache.fetch(:missing) }
        assert_equal :created, cache.store_if_absent(:missing) { :created }
        assert_equal :created, cache[:missing]
      end
    end

    def test_key_predicate_and_aliases_recognize_nil_and_false_values
      [false, true].each do |identity|
        %i[key? has_key? member? include?].each do |method|
          entries = { value: :value, nil_value: nil, false_value: false }
          cache = Strict::WeakCache.new(entries, compare_by_identity: identity)

          2.times do
            %i[value nil_value false_value].each { |key| assert_same true, cache.public_send(method, key) }
            assert_same false, cache.public_send(method, :missing)
          end
          assert_raises(KeyError) { cache.fetch(:missing) }
          assert_equal :created, cache.store_if_absent(:missing) { :created }
          assert_same true, cache.public_send(method, :missing)
        end
      end
    end

    def test_read_methods_preserve_key_comparison_and_stored_key_identity
      first = Key.new(:first).freeze
      equal = Key.new(:first).freeze
      collision = Key.new(:other).freeze
      [false, true].each do |identity|
        cache = Strict::WeakCache.new({ first => :value }, compare_by_identity: identity)

        2.times do
          assert_equal :value, cache[first]
          assert_equal :value, cache.dig(first)
          assert_same first, cache.getkey(first)
          if identity
            assert_nil cache[equal]
            assert_nil cache.dig(equal)
            assert_nil cache.getkey(equal)
          else
            assert_equal :value, cache[equal]
            assert_equal :value, cache.dig(equal)
            assert_same first, cache.getkey(equal)
          end
          %i[key? has_key? member? include?].each do |method|
            assert_equal !identity, cache.public_send(method, equal)
            refute cache.public_send(method, collision)
          end
          assert_nil cache[collision]
          assert_nil cache.dig(collision)
          assert_nil cache.getkey(collision)
        end
      end
    end

    def test_getkey_returns_keys_even_when_keys_or_values_are_nil_or_false
      [false, true].each do |identity|
        entries = { nil => :nil_key, false => :false_key, nil_value: nil, false_value: false }
        cache = Strict::WeakCache.new(entries, compare_by_identity: identity)

        assert_nil cache.getkey(nil)
        assert_same false, cache.getkey(false)
        assert_equal :nil_value, cache.getkey(:nil_value)
        assert_equal :false_value, cache.getkey(:false_value)
        assert_nil cache.getkey(:missing)
      end
    end

    def test_dig_matches_weak_value_map_for_nested_values_and_errors
      nested = { array: [{ answer: 42 }.freeze, nil, false].freeze }.freeze
      entries = { nested:, nil_value: nil, false_value: false, scalar: 42 }
      cache = Strict::WeakCache.new(entries)
      map = Strict::WeakValueMap.new(entries)

      assert_same nested, cache.dig(:nested)
      assert_equal 42, cache.dig(:nested, :array, 0, :answer)
      assert_nil cache.dig(:nested, :array, 1, :missing)
      assert_same false, cache.dig(:nested, :array, 2)
      assert_nil cache.dig(:nil_value, :missing)
      assert_nil cache.dig(:missing, :nested)
      assert_same false, cache.dig(:false_value)
      assert_equal 42, cache.dig(:scalar)
      [[], %i[false_value nested], %i[scalar nested], %i[nested array invalid]].each do |arguments|
        expected = assert_raises(StandardError) { map.dig(*arguments) }
        actual = assert_raises(expected.class) { cache.dig(*arguments) }

        assert_equal expected.message, actual.message
      end
      assert_raises(KeyError) { cache.fetch(:missing) }
    end

    def test_read_methods_normalize_mutable_string_keys_without_caching_their_identity
      stored = String.new("key").freeze
      lookup = String.new("key")
      cache = Strict::WeakCache.new({ stored => :value })

      assert_equal :value, cache[lookup]
      assert_equal :value, cache.dig(lookup)
      assert_same stored, cache.getkey(lookup)
      %i[key? has_key? member? include?].each { |method| assert cache.public_send(method, lookup) }
      refute_predicate lookup, :frozen?
      lookup.replace("missing")

      assert_nil cache[lookup]
      assert_nil cache.dig(lookup)
      assert_nil cache.getkey(lookup)
      %i[key? has_key? member? include?].each { |method| refute cache.public_send(method, lookup) }
      assert_equal :value, cache[stored]
    end

    def test_read_methods_work_on_a_frozen_cache_in_another_ractor
      key = String.new("key").freeze
      nested = { answer: 42 }.freeze
      cache = Strict::WeakCache.new({ key => nested, nil_value: nil, false_value: false }).freeze
      worker = Ractor.new(cache, key) do |shared, lookup|
        2.times.map do
          [shared[lookup], shared.key?(:nil_value), shared.has_key?(:false_value), shared.member?(lookup), # rubocop:disable Style/PreferredHashMethods
           shared.include?(:missing), shared.dig(lookup, :answer), shared.getkey(lookup), shared[:missing]]
        end
      end

      ractor_value(worker).each do |result|
        assert_equal [nested, true, true, true, false, 42, key, nil], result
        assert_same key, result[6]
      end
    end

    def test_immediate_keys_work_with_both_comparison_modes
      [false, true].each do |identity|
        cache = Strict::WeakCache.new(compare_by_identity: identity)
        [nil, false, true, :key, 42, 1.5].each_with_index do |key, index|
          assert_equal index, cache.store_if_absent(key) { index }
          assert_equal index, cache.store_if_absent(key) { flunk "recomputed an immediate key" }
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
      assert_equal :stored, cache.store_if_absent(:missing) { :stored }
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
      assert_equal :first, cache.store_if_absent(first) { :first }
      assert_equal :first, cache.store_if_absent(equal) { flunk }
      assert_equal :second, cache.store_if_absent(second) { :second }
      assert_equal :first, cache.fetch(equal)
      assert_equal :second, cache.fetch(second)
    end

    def test_identity_keys_remain_separate
      first = String.new("key").freeze
      equal = String.new("key").freeze
      cache = Strict::WeakCache.new({ first => :first }, compare_by_identity: true)

      assert_predicate cache, :compare_by_identity?
      assert_equal :first, cache.store_if_absent(first) { flunk }
      assert_equal :missing, cache.fetch(equal, :missing)
      assert_equal :second, cache.store_if_absent(equal) { :second }
      assert_equal :first, cache.fetch(first)
      assert_equal :second, cache.fetch(equal)
    end

    def test_mutable_string_keys_are_copied_for_equality_comparison
      cache = Strict::WeakCache.new
      key = String.new("key")

      assert_equal :value, cache.store_if_absent(key) { :value }
      refute_predicate key, :frozen?
      key.replace("changed")

      assert_equal :value, cache.fetch(String.new("key"))
      assert_equal :value, cache.store_if_absent(String.new("key")) { flunk }
      assert_equal :missing, cache.fetch(key, :missing)
    end

    def test_identity_comparison_rejects_mutable_string_keys
      return unless Internal.native_ractors?

      cache = Strict::WeakCache.new(compare_by_identity: true)
      key = String.new("key")

      assert_raises(Ractor::IsolationError) { cache.store_if_absent(key) { flunk } }
      assert_raises(Ractor::IsolationError) { cache.fetch(key) }
      assert_raises(Ractor::IsolationError) { cache.compute_if_absent(key) { flunk } }
      assert_raises(Ractor::IsolationError) { cache.put_if_absent(key, :value) }
      %i[[] key? has_key? member? include? dig getkey assoc values_at fetch_values].each do |method|
        assert_raises(Ractor::IsolationError) { cache.public_send(method, key) }
      end
    end

    def test_unshareable_initial_entries_are_rejected
      value = Unshared::Queue.new

      assert_raises(Ractor::IsolationError) { Strict::WeakCache.new({ key: value }) }
      assert_raises(Ractor::IsolationError) { Strict::WeakCache.new({ value => :value }) }
    end

    def test_unshareable_results_are_not_cached
      cache = Strict::WeakCache.new

      assert_raises(Ractor::IsolationError) { cache.store_if_absent(:key) { Unshared::Queue.new } }
      assert_raises(KeyError) { cache.fetch(:key) }
      assert_equal :recovered, cache.store_if_absent(:key) { :recovered }
    end

    def test_warm_local_entries_do_not_bypass_key_validation
      return unless Internal.native_ractors?

      key = Key.new(:key).freeze
      mutable_key = key.dup
      cache = Strict::WeakCache.new
      cache.store_if_absent(key) { :value }

      assert_raises(Ractor::IsolationError) { cache.store_if_absent(mutable_key) { flunk } }
      assert_raises(Ractor::IsolationError) { cache.fetch(mutable_key) }
      assert_raises(Ractor::IsolationError) { cache.compute_if_absent(mutable_key) { flunk } }
      assert_raises(Ractor::IsolationError) { cache.put_if_absent(mutable_key, :value) }
      %i[[] key? has_key? member? include? dig getkey assoc values_at fetch_values].each do |method|
        assert_raises(Ractor::IsolationError) { cache.public_send(method, mutable_key) }
      end
    end

    def test_failed_generation_can_be_retried
      cache = Strict::WeakCache.new

      error = assert_raises(RuntimeError) { cache.store_if_absent(:key) { raise "generation failed" } }

      assert_equal "generation failed", error.message
      assert_raises(KeyError) { cache.fetch(:key) }
      assert_equal :recovered, cache.store_if_absent(:key) { :recovered }
    end

    def test_nonlocal_exits_do_not_cache_a_value_or_leave_a_claim
      cache = Strict::WeakCache.new

      assert_equal :aborted, cache.store_if_absent(:key) { break :aborted }
      assert_equal :aborted, catch(:abort) { cache.store_if_absent(:key) { throw :abort, :aborted } }
      assert_raises(KeyError) { cache.fetch(:key) }
      assert_equal :recovered, cache.store_if_absent(:key) { :recovered }
    end

    def test_recursive_generation_releases_the_key
      cache = Strict::WeakCache.new

      assert_raises(ThreadError) { cache.store_if_absent(:key) { cache.store_if_absent(:key) { :recursive } } }
      assert_equal :recovered, cache.store_if_absent(:key) { :recovered }
      assert_equal :other, cache.store_if_absent(:outer) { cache.store_if_absent(:inner) { :other } }
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
          cache.store_if_absent(:key) do
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
          shared.store_if_absent(:key) do
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
        value = cache.store_if_absent(:key) do
          events << :generating
          2.times { ready.push(true) }
          raise "test release timed out" unless release.pop(timeout: 5)
          :value
        end
        events << [:generated, value]
      end
      Fiber.schedule do
        raise "test start timed out" unless ready.pop(timeout: 5)
        events << [:store_if_absent, cache.store_if_absent(:key) { flunk "generated twice" }]
      end
      Fiber.schedule do
        raise "test start timed out" unless ready.pop(timeout: 5)
        events << [:other, cache.store_if_absent(:other) { :other }]
        release.push(true)
      end
      Fiber.set_scheduler(nil)

      assert_equal [:generating, %i[other other]], events.first(2)
      assert_equal [%i[generated value], %i[store_if_absent value]], events.drop(2).sort
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
           shared.compare_by_identity?, shared.store_if_absent(:new) { :created }]
        end
        result = ractor_value(worker)

        assert_same value, result[0]
        assert_same(identity ? :missing : value, result[1])
        assert_equal identity, result[2]
        assert_equal :created, result[3]
        assert_equal :created, cache.fetch(:new)
      end
    end

    def test_freezing_prevents_store_if_absent_even_for_warm_entries
      cache = Strict::WeakCache.new
      cache.store_if_absent(:key) { :value }

      assert_same cache, cache.freeze
      assert_predicate cache, :frozen?
      assert_equal :value, cache.fetch(:key)
      assert_raises(FrozenError) { cache.store_if_absent(:key) { flunk } }
      assert_raises(FrozenError) { cache.store_if_absent(:missing) { flunk } }
    end

    def test_frozen_cache_can_fetch_from_another_ractor
      cache = Strict::WeakCache.new({ key: :value }).freeze
      worker = Ractor.new(cache) { |shared| [shared.frozen?, shared.fetch(:key), shared.fetch(:missing, :default)] }

      assert_equal [true, :value, :default], ractor_value(worker)
    end

    def test_new_map_methods_are_visible_across_ractors
      cache = Strict::WeakCache.new({ nil_value: nil }, compare_by_identity: true)
      worker = Ractor.new(cache) do |shared|
        inserted = shared.put_if_absent(:inserted, :value)
        computed = shared.compute_if_absent(:computed) { false }
        shared.freeze
        [inserted, computed, shared.values_at(:inserted, :computed, :nil_value, :missing),
         shared.fetch_values(:computed, :missing) { :default }, shared.assoc(:inserted),
         shared.compare_keys_by_identity?]
      end
      expected = [nil, false, [:value, false, nil, nil], [false, :default], %i[inserted value], true]

      assert_equal expected, ractor_value(worker)
      assert_equal :value, cache.fetch(:inserted)
      assert_same false, cache.fetch(:computed)
      assert_predicate cache, :frozen?
    end

    def test_freezing_during_generation_does_not_cache_the_result
      cache = Strict::WeakCache.new

      assert_raises(FrozenError) do
        cache.store_if_absent(:key) do
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
          assert_raises(FrozenError) { copy.store_if_absent(:new) { flunk } }
        else
          assert_equal :new, copy.store_if_absent(:new) { :new }
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
          value = cache.store_if_absent(:key) { Object.new.freeze }
          cache[:key]
          cache.key?(:key)
          cache.dig(:key)
          cache.getkey(:key)
          cache.values_at(:key)
          cache.fetch_values(:key)
          cache.assoc(:key)
          cache.put_if_absent(:key, :unused)
          cache.compute_if_absent(:key) { raise "recomputed a live value" }
          ::WeakRef.new(value)
        end.value

        assert_collected(reference, cache)
        assert_raises(KeyError) { cache.fetch(:key) }
        assert_nil cache[:key]
        assert_nil cache.dig(:key)
        assert_nil cache.getkey(:key)
        assert_equal [nil], cache.values_at(:key)
        assert_equal [:missing], cache.fetch_values(:key) { :missing }
        assert_nil cache.assoc(:key)
        %i[key? has_key? member? include?].each { |method| refute cache.public_send(method, :key) }
        assert_equal :replacement, cache.store_if_absent(:key) { :replacement }
      end
    end

    def test_initial_values_can_be_collected
      cache, reference = Thread.new do
        value = Object.new.freeze
        [Strict::WeakCache.new({ key: value }), ::WeakRef.new(value)]
      end.value

      assert_collected(reference, cache)
      assert_raises(KeyError) { cache.fetch(:key) }
      assert_equal :replacement, cache.store_if_absent(:key) { :replacement }
    end

    def test_equal_lookup_keys_can_be_collected_while_the_value_is_live
      key = Key.new(:key).freeze
      value = Object.new.freeze
      cache = Strict::WeakCache.new({ key => value })
      reference = Thread.new do
        lookup = Key.new(:key).freeze
        cache.store_if_absent(lookup) { raise "recomputed an equal key" }
        ::WeakRef.new(lookup)
      end.value

      assert_collected(reference, cache)
      assert_same value, cache.store_if_absent(Key.new(:key).freeze) { flunk }
      assert_same value, cache.fetch(key)
    end

    def test_abandoned_caches_can_be_collected_while_the_value_is_live
      value = Object.new.freeze
      reference = Thread.new do
        cache = Strict::WeakCache.new
        cache.store_if_absent(:key) { value }
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
        keys.each_with_index { |key, index| cache.store_if_absent(key) { values[index] } }
        GC.start
        GC.compact if GC.respond_to?(:compact)
        keys.each_with_index do |key, index|
          assert_same values[index], cache.store_if_absent(key) { flunk "lost a live value" }
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

# rubocop:enable Style/SingleArgumentDig
