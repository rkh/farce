# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/active_support"

module Farce
  class ActiveSupportVectorTests < Test
    TYPES = [Vector, Strict::Vector, Unshared::Vector, Local::Vector].freeze

    def test_access_and_set_operations
      TYPES.each do |type|
        array = (1..45).to_a
        vector = type.new(array)
        %i[second third fourth fifth forty_two second_to_last third_to_last].each do |method|
          assert_equal array.public_send(method), vector.public_send(method)
          assert_nil type.new.public_send(method)
        end
        [-50, -2, 0, 3, 50].each do |position|
          %i[from to].each do |method|
            assert_vector type, array.public_send(method, position), vector.public_send(method, position)
          end
        end

        assert_vector type, [1, 2, 3, 4], type.new([1, 2]).including([3, 4])
        assert_vector type, [1, 3], type.new([1, 2, 3]).excluding([2])
        assert_vector type, [1, 3], type.new([1, 2, 3]).without(2)
        assert_vector type, [1], type.new([nil, false, "", 1]).compact_blank
      end
    end

    def test_grouping_matches_array_and_returns_nested_vectors
      TYPES.each do |type|
        [[], [1], (1..7).to_a].each do |array|
          vector = type.new(array)
          %i[in_groups in_groups_of].each do |method|
            [1, 2, 5].each do |number|
              [nil, false, :pad].each do |fill|
                expected = array.public_send(method, number, fill)
                result = vector.public_send(method, number, fill)

                assert_vector type, expected, result, nested: true
                yielded = []
                returned = vector.public_send(method, number, fill) { yielded << it }
                expected_return = array.public_send(method, number, fill) { |_group| nil }

                assert_equal expected, yielded.map(&:to_a)
                yielded.each { assert_instance_of type, it }

                assert_vector type, expected_return, returned, nested: method == :in_groups
              end
            end
          end
        end
        assert_raises(ArgumentError) { type.new.in_groups_of(0) }
        assert_raises(ZeroDivisionError) { type.new.in_groups(0) }
      end
    end

    def test_split_and_callbacks_use_a_snapshot
      TYPES.each do |type|
        [[], [0], [0, 1, 0, 0, 2, 0]].each do |array|
          assert_vector type, array.split(0), type.new(array).split(0), nested: true
        end
        vector = type.new([1, 2, 3])
        result = vector.split do |value|
          vector << 4 if value == 1
          value.even?
        end

        assert_vector type, [[1], [3]], result, nested: true
        assert_equal [1, 2, 3, 4], vector.to_a
      end
    end

    def test_projection_and_ordering
      TYPES.each do |type|
        array = [{ a: 2, b: 4 }.freeze, { a: 1, b: 3 }.freeze]
        vector = type.new(array)

        assert_vector type, array.pluck(:a), vector.pluck(:a)
        assert_vector type, array.pluck(:a, :b), vector.pluck(:a, :b), nested: true
        assert_vector type, array.pick(:a, :b), vector.pick(:a, :b)
        assert_equal 2, vector.pick(:a)
        assert_nil type.new.pick(:a)
        numbers = type.new([3, 1, 2, 1])

        [true, false].each do |filter|
          assert_vector type, [3, 1, 2, 1].in_order_of(:itself, [1, 3, 1], filter:),
            numbers.in_order_of(:itself, [1, 3, 1], filter:)
        end
        assert_equal 1, numbers.minimum(:itself)
        assert_equal 3, numbers.maximum(:itself)
        assert_equal({ 1 => 1, 2 => 2, 3 => 3 }, numbers.index_by(&:itself))
        assert_equal({ 1 => :x, 2 => :x, 3 => :x }, numbers.index_with(:x))
      end
    end

    def test_conversions_and_explicit_array_results
      TYPES.each do |type|
        array = [1, 2, 3]
        vector = type.new(array)

        assert_equal array.to_sentence(locale: false), vector.to_sentence(locale: false)
        assert_equal array.to_param, vector.to_param
        assert_equal array.to_query("ids"), vector.to_query("ids")
        assert_equal array.to_fs, vector.to_fs
        assert_equal array.to_formatted_s, vector.to_formatted_s
        assert_instance_of Array, vector.as_json
        assert_equal array.as_json, vector.as_json
        assert_equal array.to_json, vector.to_json
        assert_instance_of ActiveSupport::ArrayInquirer, vector.inquiry
        assert_predicate type.new([:active]).inquiry, :active?
        %i[compact_blank! extract! extract_options!].each { refute_respond_to vector, it }
      end
    end

    def test_deep_dup_is_independent
      [Vector, Unshared::Vector, Local::Vector].each do |type|
        vector = type.new([["a"]])
        copy = vector.deep_dup

        assert_instance_of type, copy
        copy[0] << "b"

        assert_equal ["a"], vector[0]
        refute_same vector[0][0], copy[0][0]
      end
      assert_raises(Ractor::IsolationError) { Strict::Vector.new([[1].freeze]).deep_dup } if Internal.native_ractors?
      vector = Vector.new([[1]], mode: :move)
      copy = vector.deep_dup
      copy[0] << 2

      assert_equal [1], vector[0]
      assert_equal [1, 2], copy[0]
    end

    def test_retained_entries_preserve_modes_and_identity
      %i[copy local move].each do |mode|
        vector = Vector.new([Object.new, Object.new], mode:, compare_by_identity: true)
        result = vector.in_groups_of(3)

        assert_equal mode, result.mode
        assert_predicate result, :compare_by_identity?
        assert_same vector[0], result[0][0]
        assert_same vector[1], result[0][1]
        assert_nil result[0][2]
        assert_same vector[0], vector.from(0)[0]
        assert_same vector[0], vector.in_order_of(:object_id, [vector[0].object_id])[0]
      end
      source = Local::Vector.new([1, 2], scope: :fiber)
      result = source.in_groups_of(3)

      assert_equal :fiber, result.scope
      assert_equal [[1, 2, nil]], Fiber.new { result.to_a.map(&:to_a) }.resume
    end

    def test_unused_padding_does_not_transfer_values
      return unless Internal.native_ractors?

      fill = Object.new
      vector = Vector.new([1, 2], mode: :move)
      vector.in_groups_of(2, fill)

      refute_kind_of Ractor::MovedObject, fill
      result = vector.in_groups(4, fill)

      assert_same result[2][0], result[3][0]

      fill = Object.new
      yielded = []
      result = vector.in_groups_of(3, fill) { yielded << it }

      assert_same yielded[0][2], result[2]
    end

    def test_results_can_be_read_in_another_ractor
      [Vector, Strict::Vector].each do |type|
        groups = type.new([1, 2, 3]).in_groups_of(2)
        worker = Ractor.new(groups) { |value| value.to_a.map(&:to_a) }
        result = worker.respond_to?(:value) ? worker.value : worker.take

        assert_equal [[1, 2], [3, nil]], result
      end
    end

    def test_xml_conversion_matches_array_including_optional_dependency
      begin
        require "active_support/builder"
      rescue LoadError
        assert_raises(LoadError) { [1].to_xml }
        assert_raises(LoadError) { Vector.new([1]).to_xml }
        return
      end
      TYPES.each do |type|
        expected = [1, 2].to_xml(root: "items") { |xml| xml.extra "value" }
        actual = type.new([1, 2]).to_xml(root: "items") { |xml| xml.extra "value" }

        assert_equal expected, actual
      end
    end

    private

    def assert_vector(type, expected, actual, nested: false)
      assert_instance_of type, actual
      actual.each { assert_instance_of type, it } if nested

      assert_equal expected, nested ? actual.to_a.map(&:to_a) : actual.to_a
    end
  end
end
