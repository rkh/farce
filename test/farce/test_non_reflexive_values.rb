# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestNonReflexiveValues < Test
    NAMESPACES = [Farce, Strict, Unshared, Local].freeze
    MAP_NAMES = %i[Map WeakMap WeakKeyMap WeakValueMap].freeze

    class NonReflexive
      def ==(_other) = false
      def eql?(_other) = false
      def hash = 1
    end

    class MisleadingIdentity < NonReflexive
      def equal?(_other) = true

      def !=(_other)
        false
      end
    end

    def run(...) = Timeout.timeout(30) { super }

    def test_predicate_waits_suspend_for_unchanged_non_reflexive_values
      [Float::NAN, NonReflexive.new.freeze].each do |value|
        each_subject(value) do |subject, keys|
          checks = 0
          result = subject.wait_until(*keys, timeout: 0.01) do
            checks += 1
            false
          end

          assert_nil result, subject.class.name
          assert_equal 1, checks, subject.class.name
        end
      end
    end

    def test_predicate_waits_stop_when_storage_times_out_before_the_outer_deadline
      Clock.define_singleton_method(:remaining, Ractor.shareable_proc { |_deadline| 0 })

      each_subject(Float::NAN) do |subject, keys|
        checks = 0
        result = subject.wait_until(*keys, timeout: 1) do
          checks += 1
          flunk "#{subject.class} retried the predicate after storage timed out" if checks > 1
          false
        end

        assert_nil result, subject.class.name
        assert_equal 1, checks, subject.class.name
      end
    ensure
      Clock.singleton_class.remove_method(:remaining)
    end

    def test_managed_predicate_waits_observe_envelopes_without_comparing_copies
      %i[copy local move marshal].each do |mode|
        [Atom, Vector, Map].each do |type|
          subject, keys = build_subject(type, NonReflexive.new, mode:)
          checks = 0
          result = subject.wait_until(*keys, timeout: 0.01) do
            checks += 1
            false
          end

          assert_nil result, "#{type} #{mode}"
          assert_equal 1, checks, "#{type} #{mode}"
        end
      end
    end

    def test_predicate_waits_wake_after_replacing_nan
      each_subject(Float::NAN) do |subject, keys|
        checked = Thread::Queue.new
        writer = Thread.new do
          checked.pop
          store(subject, keys, :ready)
        end
        result = subject.wait_until(*keys, timeout: 5) do |value|
          checked << true
          value == :ready
        end

        assert_equal :ready, result, subject.class.name
        writer.join
      ensure
        writer&.kill
        writer&.join
      end
    end

    def test_predicate_waits_preserve_key_normalization_and_nil_results
      [Map, WeakMap, WeakKeyMap, WeakValueMap].each do |type|
        map = type.new(normalize_keys: :succ)
        map[1] = Float::NAN
        seen = []
        result = map.wait_until(1, timeout: 1) do |value|
          seen << value
          map[1] = nil if value.is_a?(Float)
          value.nil?
        end

        assert_nil result, type.name
        assert_equal 2, seen.size, type.name
        assert_predicate seen.first, :nan?
        assert_nil seen.last
        assert map.key?(1), "#{type} key missing"
        refute map.key?(2), type.name
      end
    end

    def test_walker_replaces_non_reflexive_map_values
      NAMESPACES.each do |namespace|
        MAP_NAMES.each do |name|
          type = namespace.const_get(name)
          [Float::NAN, NonReflexive.new.freeze].each do |value|
            [false, true].each do |copy|
              map = type.new({ key: value })
              result = Timeout.timeout(1) do
                Walker.modify(map, copy:) do |object, walker|
                  object.equal?(value) ? :replaced : walker.traverse
                end
              end

              assert_equal :replaced, result[:key], "#{type} copy: #{copy}"
              assert_same value, map[:key] if copy
            end
          end
        end
      end
    end

    def test_walker_replaces_copied_non_reflexive_map_values
      map = Map.new({ key: NonReflexive.new }, mode: :copy)
      result = Timeout.timeout(1) do
        Walker.modify(map) do |object, walker|
          object.is_a?(NonReflexive) ? nil : walker.traverse
        end
      end

      assert_same map, result
      assert map.key?(:key)
      assert_nil map[:key]
    end

    def test_walker_replaces_nan_under_a_normalized_key
      [Map, Strict::Map, Unshared::Map, Local::Map].each do |type|
        map = type.new(normalize_keys: :succ)
        map[1] = Float::NAN
        Walker.modify(map) do |object, walker|
          Float === object ? :replaced : walker.traverse
        end

        assert_equal :replaced, map[1], type.name
        assert_equal 1, map.size, type.name
      end
    end

    def test_walker_stages_non_reflexive_values_through_transaction_maps
      [Map, Strict::Map, Unshared::Map, Local::Map].each do |type|
        [true, false].each do |commit|
          map = type.new(normalize_keys: :succ)
          map[1] = Float::NAN
          result = Farce.transaction(retries: 0) do |transaction|
            view = transaction[map]
            Walker.modify(view) do |object, walker|
              Float === object ? :replaced : walker.traverse
            end

            assert_equal :replaced, view[1], type.name
            assert_predicate map[1], :nan?
            transaction.abort! unless commit
          end

          assert_equal commit, result, type.name
          if commit
            assert_equal :replaced, map[1], type.name
          else
            assert_predicate map[1], :nan?
          end
        end
      end
    end

    def test_repeated_insertion_preserves_non_reflexive_key_identity
      NAMESPACES.each do |namespace|
        MAP_NAMES.each do |name|
          type = namespace.const_get(name)
          [Float::NAN, NonReflexive.new.freeze].each do |key|
            map = type.new
            5.times { |value| map[key] = value }

            assert_equal 1, map.size, type.name
            assert map.key?(key), "#{type} key missing"
            assert_equal 4, map[key], type.name
            assert_same key, map.getkey(key), type.name
            assert_equal 4, map.delete(key), type.name
            assert_empty map, type.name
          end
        end
      end
    end

    def test_sets_preserve_non_reflexive_member_identity
      NAMESPACES.each do |namespace|
        %i[Set WeakSet].each do |name|
          type = namespace.const_get(name)
          [Float::NAN, NonReflexive.new.freeze].each do |value|
            set = type.new

            assert_same set, set.add?(value), type.name
            5.times { assert_nil set.add?(value), type.name }
            assert_equal 1, set.size, type.name
            assert_includes set, value
            assert_same set, set.delete?(value), type.name
            assert_empty set, type.name
          end
        end
      end
    end

    def test_distinct_non_reflexive_keys_remain_distinct
      NAMESPACES.each do |namespace|
        keys = [MisleadingIdentity.new.freeze, MisleadingIdentity.new.freeze]
        map = namespace.const_get(:Map).new
        keys.each_with_index { |key, index| map[key] = index }

        assert_equal 2, map.size, map.class.name
        assert_equal [0, 1], keys.map { map[it] }, map.class.name
      end
    end

    def test_observation_changes_do_not_use_overridden_identity_or_inequality
      original = MisleadingIdentity.new.freeze
      replacement = MisleadingIdentity.new.freeze
      each_subject(original) do |subject, keys|
        store(subject, keys, replacement)
        result = subject.wait_until_changed(*keys, original, timeout: 0)

        assert_same replacement, result, subject.class.name
      end
    end

    private

    def each_subject(value)
      NAMESPACES.each do |namespace|
        (%i[Atom WeakAtom Vector] + MAP_NAMES).each do |name|
          yield(*build_subject(namespace.const_get(name), value))
        end
      end
    end

    def build_subject(type, value, **)
      if type < Abstract::Map
        [type.new({ key: value }, **), [:key]]
      elsif type < Abstract::Vector
        [type.new([value], **), [0]]
      else
        [type.new(value, **), []]
      end
    end

    def store(subject, keys, value)
      if keys.empty?
        subject.value = value
      else
        subject[keys.first] = value
      end
    end
  end
end
