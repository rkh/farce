# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # A {Abstract::Vector Vector} that is part of a transaction.
    class Vector < Abstract::Vector
      include Wrapper

      # (see Abstract::Vector#compare_by_identity?)
      # @see Abstract::Vector#compare_by_identity?
      def compare_by_identity? = access { @object.compare_by_identity? }

      # (see Abstract::Vector#shareable_values?)
      # @see Abstract::Vector#shareable_values?
      def shareable_values? = access { @object.shareable_values? }

      # (see Abstract::Vector#[])
      # @see Abstract::Vector#[]
      def [](index, length = UNDEFINED)
        access do
          next unwrap_stored(@working[index]) if length.equal?(UNDEFINED) && !index.is_a?(Range)
          slice(index, length)
        end
      end

      # (see Abstract::Vector#get)
      # @see Abstract::Vector#get
      def get(index) = self[index]

      # (see Abstract::Vector#size)
      # @see Abstract::Vector#size
      def size = access { @working.size }

      # (see Abstract::Vector#empty?)
      # @see Abstract::Vector#empty?
      def empty? = size.zero?

      # (see Abstract::Vector#[]=)
      # @see Abstract::Vector#[]=
      def []=(index, value, replacement = UNDEFINED)
        if replacement.equal?(UNDEFINED) && !index.is_a?(Range)
          store(index, value)
        else
          write { assign_vector_slice(index, value, replacement) }
        end
      end

      # (see Abstract::Vector#store)
      # @see Abstract::Vector#store
      def store(index, value, mode: nil)
        write { unwrap_stored(@working.store(index, wrap(value, mode:))) }
      end

      # (see Abstract::Vector#swap)
      # @see Abstract::Vector#swap
      def swap(index, value, mode: nil)
        write { unwrap_stored(@working.swap(index, wrap(value, mode:))) }
      end

      # (see Abstract::Vector#push)
      # @see Abstract::Vector#push
      def push(value = UNDEFINED, *rest, mode: nil)
        write do
          if rest.empty? && !value.equal?(UNDEFINED)
            @working.push(wrap(value, mode:))
          else
            push_values(value.equal?(UNDEFINED) ? rest : [value, *rest], mode:)
          end
        end
        self
      end

      def <<(value) = push(value)

      # (see Abstract::Vector#pop)
      # @see Abstract::Vector#pop
      def pop(count = UNDEFINED)
        write { count.equal?(UNDEFINED) ? unwrap_stored(@working.pop) : pop_values(count) }
      end

      # (see Abstract::Vector#clear)
      # @see Abstract::Vector#clear
      def clear
        write { @working.clear }
        self
      end

      # (see Abstract::Vector#each)
      # @see Abstract::Vector#each
      def each
        return enum_for(__method__) unless block_given?
        access { @working.snapshot.each { |value| yield unwrap_stored(value) } }
        self
      end

      # (see Abstract::Vector#update)
      # @see Abstract::Vector#update
      def update(index, mode: nil)
        require_block!(block_given?)
        write { unwrap_stored(@working.update(index) { |value| wrap(yield(unwrap_stored(value)), mode:) }) }
      end

      # (see Abstract::Vector#store_if_absent)
      # @see Abstract::Vector#store_if_absent
      def store_if_absent(index, mode: nil)
        require_block!(block_given?)
        write { unwrap_stored(@working.store_if_absent(index) { wrap(yield, mode:) }) }
      end

      # (see Abstract::Vector#upsert)
      # @see Abstract::Vector#upsert
      def upsert(index, initial, mode: nil)
        require_block!(block_given?)
        write do
          unwrap_stored(@working.upsert(index, wrap(initial, mode:)) do |value|
            wrap(yield(unwrap_stored(value)), mode:)
          end)
        end
      end

      # (see Abstract::Vector#compare_and_set)
      # @see Abstract::Vector#compare_and_set
      def compare_and_set(index, expected, replacement, mode: nil)
        write do
          next compared(@working.compare_and_set(index, expected, replacement)) unless @manager
          index = Integer(index)
          next compared(false) unless index >= -@working.size && index < @working.size &&
            matches?(@working[index], expected, identity: @object.compare_by_identity?)
          @working.store(index, wrap(replacement, mode:))
          true
        end
      end

      protected

      def internal_vector = @working
      def logical_value(value) = unwrap_stored(value)

      def deletion_comparison(value)
        return value unless @manager
        @manager.wrap(value, mode: compare_by_identity? ? :local : :copy)
      end

      def deletion_match?(stored, expected)
        return super unless @manager
        unwrap_stored(stored)
        @manager.same_value?(stored, expected, identity: compare_by_identity?)
      end

      # Slice helpers return independent data rather than another participant.
      # Use an ordinary vector that remains usable after the attempt ends.
      def build_derived_vector(values)
        Unshared::Vector.new(values.map { unwrap_stored(it) }, compare_by_identity: compare_by_identity?)
      end

      private

      def inspect_value(inspector, value) = super(inspector, value, @manager)
      def derived_storage(value)          = wrap(value)
      def prepare_vector_value(value, mode: nil) = wrap(value, mode:)

      Wrapper.inherit(self, :each_index, :reverse_each, :to_a, :to_ary, :deconstruct, :to_h, :join, :dig, :assoc,
        :rassoc, :at, :fetch, :fetch_values, :values_at, :slice, :rfind, :bsearch, :bsearch_index, :pack,
        :length, :count, :compare_by_identity?, :shareable_values?, :flatten, :transpose, :product,
        :combination, :repeated_combination, :permutation, :repeated_permutation, :<=>,
        writes: %i[delete delete_if map! collect! keep_if select! filter! reject! compact! uniq!
                   reverse! rotate! shuffle! sort! sort_by! flatten! shift unshift prepend insert delete_at slice!
                   replace fill append])
    end
  end
end
