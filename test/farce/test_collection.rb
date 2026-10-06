# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestCollection < Test
    include Helpers::InternalTestHelpers

    TYPES = [Set, SortedSet, WeakSet, Vector,
             Strict::Set, Strict::SortedSet, Strict::WeakSet, Strict::Vector,
             Unshared::Set, Unshared::SortedSet, Unshared::WeakSet, Unshared::Vector,
             Local::Set, Local::SortedSet, Local::WeakSet, Local::Vector].freeze

    def test_count_with_and_without_an_item_or_block
      TYPES.each do |type|
        collection = type.new([1, 2, 2, 3])
        duplicates = type <= Abstract::Vector

        assert_equal duplicates ? 4 : 3, collection.count, type.name
        assert_equal duplicates ? 2 : 1, collection.count(2), type.name
        assert_equal(2, collection.count(&:odd?), type.name)
        assert_equal 0, collection.count(99), type.name
        assert_equal 0, type.new.count, type.name
      end
    end

    def test_count_accepts_nil_and_false_as_items
      TYPES.reject { it <= Abstract::SortedSet }.each do |type|
        collection = type.new([nil, false, 1])

        assert_equal 1, collection.count(nil), type.name
        assert_equal 1, collection.count(false), type.name
        assert_equal(1, collection.count { it }, type.name)
      end
    end

    def test_count_ignores_the_block_when_an_item_is_supplied
      TYPES.each do |type|
        collection = type.new([1, 2])
        calls = 0

        assert_output("", /given block not used/) do
          assert_equal(1, collection.count(2) { calls += 1 }, type.name)
        end

        assert_equal 0, calls, type.name
      end
    end

    def test_argumentless_count_keeps_move_values_available
      return unless Internal.native_ractors?

      [Set, SortedSet, Vector].each do |type|
        collection = type.new(["value".dup], mode: :move)
        expected = "#<#{type.name} [unclaimed]>"

        assert_equal 1, collection.count
        assert_equal expected, collection.inspect
        assert Transaction.run(collection) { |_, wrapped|
          assert_equal 1, wrapped.count
        }
        assert_equal expected, collection.inspect
        worker = Ractor.new(collection) { |shared| shared.first.to_sym }

        assert_equal :value, ractor_value(worker)
      end
    end

    def test_transaction_helpers_observe_staged_values_and_reject_invalid_access
      TYPES.reject { it <= Abstract::WeakSet }.each do |type|
        collection = type.new([1, 2])
        wrapper = nil
        methods = %i[count length empty? join]

        assert Transaction.run(collection) { |_, wrapped|
          wrapper = wrapped

          assert_equal 2, wrapped.count
          assert_equal 1, wrapped.count(2)
          assert_equal(1, wrapped.count(&:even?))
          assert_equal 2, wrapped.length
          refute_empty wrapped
          wrapped.clear

          assert_equal 0, wrapped.count
          assert_equal 0, wrapped.length
          assert_empty wrapped
          assert_equal "", wrapped.join
          methods.each do |method|
            error = Fiber.new do
              wrapped.public_send(method)
            rescue StandardError => e
              e
            end.resume

            assert_instance_of Transaction::OwnershipError, error
          end
        }
        methods.each { |method| assert_raises(Transaction::ClosedError) { wrapper.public_send(method) } }
      end
    end
  end
end
