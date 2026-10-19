# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Abstract
    # @abstract Superclass for concurrent indexed collections.
    # Negative indexes count from the end. Assignments beyond the end fill gaps with nil.
    # Atomic updates reserve the entire vector. Reads through {#[]} do not wait for updates.
    # Timeouts are finite, non-negative seconds. Nil waits indefinitely for access.
    class Vector < Collection
      include Internal::MarshalSupport::Vector

      # @api private
      def transaction_wrapper(transaction) = Transaction::Vector.new(transaction, self, internal_vector)

      # Iterate over live entries, up to the length when enumeration starts.
      # Changes can affect entries not yet visited. Indexes beyond the starting length are not visited.
      # Each entry is read separately. The block runs without holding a collection lock.
      # @yield [value] Called for each entry. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [void] The result is ignored.
      # @return [self, Enumerator]
      def each
        return enum_for(__method__) { size } unless block_given?

        internal_vector.each { yield logical_value(it) }
        self
      end

      # Iterate over indexes up to the length when enumeration starts.
      # @yield [index] Called for each index. Returns an Enumerator without a block.
      # @yieldparam index [Integer] The current index.
      # @yieldreturn [void] The result is ignored.
      # @return [self, Enumerator]
      def each_index(&)
        return enum_for(__method__) { size } unless block_given?

        size.times(&)
        self
      end

      # Iterate over live entries from the last index when enumeration starts.
      # Replacements and removals can affect entries not yet visited. The block runs without a collection lock.
      # @yield [value] Called for each entry. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [void] The result is ignored.
      # @return [self, Enumerator]
      def reverse_each
        return enum_for(__method__) { size } unless block_given?

        internal_vector.reverse_each { yield logical_value(it) }
        self
      end

      # Return a new Array containing a logical snapshot of the values.
      # @return [Array<BasicObject>] A new Array of logical values.
      def to_a = internal_vector.snapshot.map! { logical_value(it) }

      # Return an Array snapshot for implicit Array conversion, such as `[].concat(vector)`.
      # @return [Array<BasicObject>] A new Array of logical values.
      def to_ary = to_a

      # (see #to_a)
      def deconstruct = to_a

      # Remove all matching values using the configured comparison mode.
      # Other writers wait until the comparison finishes. Reads can observe the original values.
      # Comparison callbacks must not write to this vector.
      # @param value [BasicObject] The value to remove.
      # @yield [value] Called only when no entry matches, after releasing update access.
      # @yieldparam value [BasicObject] The requested value.
      # @yieldreturn [BasicObject] The fallback result.
      # @return [BasicObject, nil] The last removed value, or the fallback result. Nil if absent without a block.
      def delete(value)
        expected = deletion_comparison(value)
        removed = UNDEFINED
        mutate_vector do |values|
          values.delete_if do |stored|
            next false unless deletion_match?(stored, expected)
            removed = stored
            true
          end
        end
        return logical_value(removed) unless removed.equal?(UNDEFINED)
        yield(value) if block_given?
      end

      # Atomically remove entries for which the block returns a truthy value.
      # The block runs without a collection lock. Other writers wait for update access.
      # The block must not write to this vector.
      # Reads can observe the original values. If the block raises, no entries are removed.
      # @yield [value] Called once for each logical value. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] A truthy value to remove the entry.
      # @return [self, Enumerator]
      def delete_if
        return enum_for(__method__) { size } unless block_given?
        mutate_vector { |values| values.delete_if { yield logical_value(it) } }
        self
      end

      # Convert pair-like entries to a Hash. Vector entries are accepted as pairs.
      # @yield [value] Optionally transform each entry into a key-value pair.
      # @yieldparam value [BasicObject] The current entry.
      # @yieldreturn [Array, Vector] A two-element key-value pair.
      # @return [Hash] The converted pairs. Without a block, entries must be pair-like.
      def to_h = to_a.to_h { normalize_hash_pair(block_given? ? yield(it) : it) }

      # Recursively retrieve a nested value.
      # @param index [Integer] The initial index. Negative indexes count from the end.
      # @param identifiers [Array<BasicObject>] Indexes or keys passed to the nested value's `dig` method.
      # @return [BasicObject, nil] The nested value, or nil if an intermediate value is nil.
      def dig(index, *identifiers)
        value = at(index)
        return value if identifiers.empty?
        return if value.nil?
        raise TypeError, "#{value.class} does not have #dig method" unless value.respond_to?(:dig)
        value.dig(*identifiers)
      end

      # Find the first pair whose first value equals key.
      # @param key [BasicObject] The value to compare with each pair's first entry.
      # @return [Array, Vector, nil] The first matching pair, or nil if none matches.
      def assoc(key) = find_pair(key, 0)

      # Find the first pair whose second value equals value.
      # @param value [BasicObject] The value to compare with each pair's second entry.
      # @return [Array, Vector, nil] The first matching pair, or nil if none matches.
      def rassoc(value) = find_pair(value, 1)

      # (see #[])
      def at(index) = self[index]

      # Fetch a value by index, with Array-compatible fallback behavior.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @param fallback [Array<BasicObject>] At most one default value for a missing index.
      # @yield [index] Called for a missing index. Takes precedence over the default value.
      # @yieldparam index [BasicObject] The original index argument, before integer conversion.
      # @yieldreturn [BasicObject] The fallback value.
      # @return [BasicObject] The entry, default value, or block result.
      # @raise [IndexError] If the index is absent and neither a default nor a block is supplied.
      def fetch(index, *fallback)
        original_index = index
        index          = convert_vector_index(index)

        if fallback.length > 1
          raise ArgumentError, "wrong number of arguments (given #{fallback.length + 1}, expected 1..2)"
        end

        warn("block supersedes default value argument") if !fallback.empty? && block_given?

        return logical_value(internal_vector.fetch(index)) if fallback.empty? && !block_given?

        stored = internal_vector.fetch(index) do
          return yield(original_index) if block_given?
          return fallback.first
        end

        logical_value(stored)
      end

      # Fetch several values. Missing indexes are passed to the block.
      # @param indexes [Array<Integer>] The indexes to fetch.
      # @yield [index] Called for each missing index when a block is supplied.
      # @yieldparam index [BasicObject] The original missing index argument.
      # @yieldreturn [BasicObject] The fallback value.
      # @return [Vector] The requested entries and fallback values.
      # @raise [IndexError] If an index is absent and no block is supplied.
      def fetch_values(*indexes)
        values = if block_given?
                   indexes.map { |index| internal_vector.fetch(index) { derived_storage(yield(index)) } }
                 else
                   indexes.map { internal_vector.fetch(it) }
                 end
        build_derived_vector(values)
      end

      # Select values at indexes and ranges.
      # @overload values_at(*indexes)
      #   @param indexes [Array<Integer, Range>] The indexes and ranges to select.
      #   @return [Vector] The selected entries, with nil for missing positions.
      def values_at(...) = build_derived_vector(internal_vector.snapshot.values_at(...))

      # Return one value, or a Vector when a count is supplied.
      # @param count [Integer] The maximum number of entries. Omit to return one entry.
      # @return [BasicObject, Vector, nil] The first entry, nil if empty, or a Vector when count is supplied.
      def first(count = UNDEFINED)
        return self[0] if count.equal?(UNDEFINED)

        snapshot = internal_vector.snapshot
        build_derived_vector(snapshot.first(count))
      end

      # Return one value, or a Vector when a count is supplied.
      # @param count [Integer] The maximum number of entries. Omit to return one entry.
      # @return [BasicObject, Vector, nil] The last entry, nil if empty, or a Vector when count is supplied.
      def last(count = UNDEFINED)
        return self[-1] if count.equal?(UNDEFINED)

        snapshot = internal_vector.snapshot
        build_derived_vector(snapshot.last(count))
      end

      # Return an element or subsequence from a snapshot.
      # Range and start-length results are Vectors.
      # @param index [Integer, Range] An index, range, or start index when length is supplied.
      # @param length [Integer] The maximum length of a subsequence. Omit for a single index or range.
      # @return [BasicObject, Vector, nil] A single entry, a Vector subsequence, or nil for an invalid slice.
      def slice(index, length = UNDEFINED)
        snapshot = internal_vector.snapshot

        if length.equal?(UNDEFINED)
          result = snapshot.slice(index)
          return logical_value(result) unless index.is_a?(Range)
        else
          result = snapshot.slice(index, length)
        end

        result && build_derived_vector(result)
      end

      # Return whether a live entry equals value.
      # @param value [BasicObject] The value to find using `==`.
      # @return [Boolean] Whether a matching entry exists.
      def include?(value)
        each { return true if array_value_equal?(it, value) }
        false
      end
      alias member? include?

      # Return the first matching index.
      # @param value [BasicObject] The value to find. Omit to use the block.
      # @yield [entry] Test each entry when value is omitted.
      # @yieldparam entry [BasicObject] The current entry.
      # @yieldreturn [BasicObject] A truthy value for a match.
      # @return [Integer, nil, Enumerator] The matching index, nil if absent, or an Enumerator without a value or block.
      def index(value = UNDEFINED)
        return enum_for(__method__) { size } if value.equal?(UNDEFINED) && !block_given? # rubocop:disable Lint/ToEnumArguments

        warn("given block not used") if !value.equal?(UNDEFINED) && block_given?
        each_with_index do |entry, index|
          return index if value.equal?(UNDEFINED) ? yield(entry) : array_value_equal?(entry, value)
        end
        nil
      end
      alias find_index index

      # Return the last matching index.
      # @param value [BasicObject] The value to find. Omit to use the block.
      # @yield [entry] Test each entry when value is omitted.
      # @yieldparam entry [BasicObject] The current entry.
      # @yieldreturn [BasicObject] A truthy value for a match.
      # @return [Integer, nil, Enumerator] The matching index, nil if absent, or an Enumerator without a value or block.
      def rindex(value = UNDEFINED)
        return enum_for(__method__) { size } if value.equal?(UNDEFINED) && !block_given? # rubocop:disable Lint/ToEnumArguments

        warn("given block not used") if !value.equal?(UNDEFINED) && block_given?
        backend = internal_vector
        index = backend.size
        while index.positive?
          index -= 1
          found = true
          stored = backend.fetch(index) { found = false }
          next unless found
          entry = logical_value(stored)
          return index if value.equal?(UNDEFINED) ? yield(entry) : array_value_equal?(entry, value)
        end
        nil
      end

      # Find a value by searching from the end.
      # @param if_none [#call, nil] Called without arguments if no entry matches.
      # @yield [value] Test entries from last to first.
      # @yieldparam value [BasicObject] The current entry.
      # @yieldreturn [BasicObject] A truthy value for a match.
      # @return [BasicObject, nil, Enumerator] The matching entry, the fallback result, or an Enumerator without a
      #   block.
      def rfind(if_none = nil)
        return enum_for(__method__, if_none) { size } unless block_given?

        reverse_each { return it if yield(it) }
        if_none&.call
      end

      # Transform a snapshot into a Vector.
      # @yield [value] Transform each entry. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The replacement value.
      # @return [Vector, Enumerator]
      def map
        return enum_for(__method__) { size } unless block_given?

        snapshot = internal_vector.snapshot
        logical  = []
        mapped   = snapshot.map do |stored|
          value  = logical_value(stored)
          logical << value
          yield value
        end
        build_derived_from_logical(mapped, snapshot, logical)
      end
      alias collect map

      # Keep values accepted by a block.
      # @yield [value] Test each entry. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] A truthy value to retain the entry.
      # @return [Vector, Enumerator]
      def select
        return enum_for(__method__) { size } unless block_given?

        build_derived_vector(internal_vector.each.select { yield logical_value(it) })
      end
      alias filter select
      alias find_all select

      # Remove values accepted by a block.
      # @yield [value] Test each entry. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] A truthy value to exclude the entry.
      # @return [Vector, Enumerator]
      def reject
        return enum_for(__method__) { size } unless block_given?

        build_derived_vector(internal_vector.each.reject { yield logical_value(it) })
      end

      # Transform accepted values into a Vector.
      # @yield [value] Transform each entry. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The replacement value. Nil and false results are omitted.
      # @return [Vector, Enumerator]
      def filter_map
        return enum_for(__method__) { size } unless block_given?

        snapshot = internal_vector.snapshot
        logical  = []
        values   = []

        snapshot.each do |stored|
          value = logical_value(stored)
          logical << value
          mapped = yield(value)
          values << mapped if mapped
        end

        build_derived_from_logical(values, snapshot, logical)
      end

      # Transform and flatten one Array or Vector level.
      # @yield [value] Transform each entry. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] An Array or Vector to expand by one level, or a single value to retain.
      # @return [Vector, Enumerator]
      def flat_map
        return enum_for(__method__) { size } unless block_given?

        snapshot = internal_vector.snapshot
        logical  = []
        values   = []
        snapshot.each do |stored|
          value = logical_value(stored)
          logical << value
          mapped = yield(value)
          converted = mapped.is_a?(Vector) ? mapped.to_a : Array.try_convert(mapped)
          values.concat(converted || [mapped])
        end
        build_derived_from_logical(values, snapshot, logical)
      end
      alias collect_concat flat_map

      # Replace each entry with the block result, publishing all replacements together.
      # The block must not write to this vector. Failure leaves the stored entries unchanged.
      # @yield [value] Transform each logical value. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The replacement value.
      # @return [self, Enumerator]
      def map!
        return enum_for(__method__) { size } unless block_given?
        mutate_vector do |values|
          logical = values.map { logical_value(it) }
          mapped = logical.map { yield it }
          values.replace(storage_from_logical(mapped, values, logical))
        end
        self
      end
      alias collect! map!

      # Keep entries accepted by the block, publishing the result atomically.
      # The block must not write to this vector.
      # @yield [value] Test each logical value. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] A truthy value to retain the entry.
      # @return [self, Enumerator]
      def keep_if
        return enum_for(__method__) { size } unless block_given?
        mutate_vector { |values| values.keep_if { yield logical_value(it) } }
        self
      end

      # Keep entries accepted by the block, returning nil if no entry was removed.
      # The block must not write to this vector.
      # @yield [value] Test each logical value. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] A truthy value to retain the entry.
      # @return [self, nil, Enumerator]
      def select!
        return enum_for(__method__) { size } unless block_given?
        changed = mutate_vector { |values| values.select! { yield logical_value(it) } }
        self if changed
      end
      alias filter! select!

      # Remove entries accepted by the block, returning nil if no entry was removed.
      # The block must not write to this vector.
      # @yield [value] Test each logical value. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] A truthy value to remove the entry.
      # @return [self, nil, Enumerator]
      def reject!
        return enum_for(__method__) { size } unless block_given?
        changed = mutate_vector { |values| values.reject! { yield logical_value(it) } }
        self if changed
      end

      # Remove nil entries atomically.
      # @return [self, nil] Self if entries were removed, otherwise nil.
      def compact!
        changed = mutate_vector(&:compact!)
        self if changed
      end

      # Remove duplicate entries atomically, retaining the first stored entry.
      # The block must not write to this vector.
      # @yield [value] Optionally compute a key for each logical value.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The key compared using `hash` and `eql?`.
      # @return [self, nil] Self if entries were removed, otherwise nil.
      def uniq!
        changed = mutate_vector do |values|
          values.uniq! { block_given? ? yield(logical_value(it)) : logical_value(it) }
        end
        self if changed
      end

      # Reverse all entries atomically.
      # @return [self]
      def reverse!
        mutate_vector(&:reverse!)
        self
      end

      # Rotate all entries atomically.
      # @param count [Integer] The rotation distance. Negative values rotate right.
      # @return [self]
      def rotate!(count = 1)
        mutate_vector { it.rotate!(count) }
        self
      end

      # Shuffle all entries atomically without transferring retained values again.
      # @param random [#rand] The random number generator.
      # @return [self]
      def shuffle!(random: Random)
        mutate_vector { it.shuffle!(random:) }
        self
      end

      # Sort all entries atomically using logical values.
      # The comparison block must not write to this vector.
      # @yield [left, right] Optionally compare two entries. Otherwise uses `<=>`.
      # @yieldparam left [BasicObject] The left entry.
      # @yieldparam right [BasicObject] The right entry.
      # @yieldreturn [Numeric] A negative number, zero, or a positive number.
      # @return [self]
      def sort!(&block)
        mutate_vector do |values|
          logical = values.map { logical_value(it) }
          sorted = block ? logical.sort(&block) : logical.sort
          values.replace(storage_from_logical(sorted, values, logical))
        end
        self
      end

      # Sort all entries atomically by the block result.
      # The block must not write to this vector.
      # @yield [value] Compute a key. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current logical value.
      # @yieldreturn [BasicObject] The sort key.
      # @return [self, Enumerator]
      def sort_by!
        return enum_for(__method__) { size } unless block_given?
        mutate_vector { |values| values.sort_by! { yield logical_value(it) } }
        self
      end

      # Expand nested Arrays and Vectors into a new Vector.
      # @param level [Integer] The maximum depth. Negative values expand every level.
      # @return [Vector] The flattened logical values.
      # @raise [ArgumentError] If the expanded graph is recursive.
      def flatten(level = -1)
        snapshot = internal_vector.snapshot
        logical = snapshot.map { logical_value(it) }
        retained = retained_storage_index(snapshot, logical)
        flattened = flatten_vector_values(logical, level, retained)
        build_derived_vector(sequence_storage(flattened, retained))
      end

      # Expand nested Arrays and Vectors atomically.
      # @param level [Integer] The maximum depth. Negative values expand every level.
      # @return [self, nil] Self if nesting was expanded, otherwise nil.
      # @raise [ArgumentError] If the expanded graph is recursive.
      def flatten!(level = -1)
        changed = mutate_vector do |values|
          logical = values.map { logical_value(it) }
          retained = retained_storage_index(values, logical)
          flattened = flatten_vector_values(logical, level, retained)
          next if flattened.equal?(logical)
          values.replace(sequence_storage(flattened, retained))
        end
        self if changed
      end

      # Transpose rows represented by Arrays or Vectors.
      # @return [Vector] A Vector containing same-kind column Vectors.
      # @raise [IndexError] If rows have different lengths.
      def transpose
        retained = {}.compare_by_identity
        rows = to_a.map { sequence_operand(it, retained) }
        columns = rows.transpose.map { build_derived_vector(sequence_storage(it, retained)) }
        build_derived_values(columns)
      end

      # Produce tuples containing one entry from each sequence.
      # @param others [Array<Vector, #to_ary>] The other sequences.
      # @yield [tuple] Optionally visit each tuple instead of collecting results.
      # @yieldparam tuple [Vector] A same-kind Vector containing the tuple.
      # @yieldreturn [void] The result is ignored.
      # @return [Vector, self] Collected tuples, or self when a block is supplied.
      def product(*others)
        snapshot = internal_vector.snapshot
        logical = snapshot.map { logical_value(it) }
        retained = retained_storage_index(snapshot, logical)
        operands = others.map { sequence_operand(it, retained) }
        if block_given?
          logical.product(*operands) { yield build_derived_vector(sequence_storage(it, retained)) }
          self
        else
          tuples = logical.product(*operands).map { build_derived_vector(sequence_storage(it, retained)) }
          build_derived_values(tuples)
        end
      end

      # Visit combinations of entries in a snapshot.
      # @param count [Integer] The number of entries per combination.
      # @yield [tuple] Visit each combination. Returns a sized Enumerator without a block.
      # @yieldparam tuple [Vector] A same-kind Vector containing the combination.
      # @yieldreturn [void] The result is ignored.
      # @return [self, Enumerator]
      def combination(count, &block) = vector_combinations(__method__, [count], block)

      # Visit combinations that may reuse entries in a snapshot.
      # @param count [Integer] The number of entries per combination.
      # @yield [tuple] Visit each combination. Returns a sized Enumerator without a block.
      # @yieldparam tuple [Vector] A same-kind Vector containing the combination.
      # @yieldreturn [void] The result is ignored.
      # @return [self, Enumerator]
      def repeated_combination(count, &block) = vector_combinations(__method__, [count], block)

      # Visit permutations of entries in a snapshot.
      # @param count [Integer] The number of entries per permutation. Defaults to the vector's length.
      # @yield [tuple] Visit each permutation. Returns a sized Enumerator without a block.
      # @yieldparam tuple [Vector] A same-kind Vector containing the permutation.
      # @yieldreturn [void] The result is ignored.
      # @return [self, Enumerator]
      def permutation(count = UNDEFINED, &block)
        vector_combinations(__method__, count.equal?(UNDEFINED) ? [] : [count], block)
      end

      # Visit permutations that may reuse entries in a snapshot.
      # @param count [Integer] The number of entries per permutation.
      # @yield [tuple] Visit each permutation. Returns a sized Enumerator without a block.
      # @yieldparam tuple [Vector] A same-kind Vector containing the permutation.
      # @yieldreturn [void] The result is ignored.
      # @return [self, Enumerator]
      def repeated_permutation(count, &block) = vector_combinations(__method__, [count], block)

      # Remove nil values.
      # @return [Vector] A new same-kind Vector containing the result.
      def compact = build_derived_vector(internal_vector.each.compact)

      # Remove duplicate values, retaining the first stored entry.
      # @yield [value] Optionally compute a comparison key for each entry.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The key compared using `hash` and `eql?`. Without a block, entries are compared
      #   directly.
      # @return [Vector]
      def uniq
        snapshot = internal_vector.snapshot
        selected = if block_given?
                     snapshot.uniq { yield logical_value(it) }
                   else
                     snapshot.uniq { logical_value(it) }
                   end
        build_derived_vector(selected)
      end

      # Return a reversed snapshot.
      # @return [Vector] A new same-kind Vector containing the result.
      def reverse = build_derived_vector(internal_vector.snapshot.reverse)

      # Return a rotated snapshot.
      # @param count [Integer] The rotation distance. Negative values rotate right.
      # @return [Vector] The rotated entries.
      def rotate(count = 1) = build_derived_vector(internal_vector.snapshot.rotate(count))

      # Return a sorted snapshot.
      # @yield [left, right] Optionally compare two entries. Without a block, uses `<=>`.
      # @yieldparam left [BasicObject] The left entry.
      # @yieldparam right [BasicObject] The right entry.
      # @yieldreturn [Numeric] A negative number, zero, or a positive number for less than, equal to, or greater than.
      # @return [Vector] The sorted entries.
      def sort(&block)
        snapshot = internal_vector.snapshot
        logical  = snapshot.map { logical_value(it) }
        sorted   = block ? logical.sort(&block) : logical.sort
        build_derived_from_logical(sorted, snapshot, logical)
      end

      # Sort a snapshot by block results.
      # @yield [value] Compute a sort key. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The key used to order the entry.
      # @return [Vector, Enumerator]
      def sort_by
        return enum_for(__method__) { size } unless block_given?

        snapshot = internal_vector.snapshot
        logical  = snapshot.map { logical_value(it) }
        build_derived_from_logical(logical.sort_by { yield it }, snapshot, logical)
      end

      # Return the first count entries.
      # @param count [Integer] The non-negative number of entries to take.
      # @return [Vector] The resulting entries.
      def take(count) = build_derived_vector(internal_vector.each.take(count))

      # Return all entries after count entries.
      # @param count [Integer] The non-negative number of entries to drop.
      # @return [Vector] The resulting entries.
      def drop(count) = build_derived_vector(internal_vector.each.drop(count))

      # Return entries before the first rejected value.
      # @yield [value] Test each entry. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] A truthy value to continue retaining entries.
      # @return [Vector, Enumerator]
      def take_while
        return enum_for(__method__) { size } unless block_given?
        build_derived_vector(internal_vector.each.take_while { yield logical_value(it) })
      end

      # Drop entries before the first rejected value.
      # @yield [value] Test each entry. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] A truthy value to continue dropping entries.
      # @return [Vector, Enumerator]
      def drop_while
        return enum_for(__method__) { size } unless block_given?
        build_derived_vector(internal_vector.each.drop_while { yield logical_value(it) })
      end

      # Return a shuffled snapshot.
      # @param random [#rand] The random number generator.
      # @return [Vector] The shuffled entries.
      def shuffle(random: Random) = build_derived_vector(internal_vector.snapshot.shuffle(random:))

      # Return one sample, or a Vector when count is supplied.
      # @param count [Integer] The maximum sample size. Omit to return one entry.
      # @param random [#rand] The random number generator.
      # @return [BasicObject, Vector, nil] One entry, nil if empty, or a Vector when count is supplied.
      def sample(count = UNDEFINED, random: Random)
        snapshot = internal_vector.snapshot
        return logical_value(snapshot.sample(random:)) if count.equal?(UNDEFINED)
        build_derived_vector(snapshot.sample(count, random:))
      end

      # Concatenate a snapshot with another sequence.
      # @param other [Vector, #to_ary] The other sequence.
      # @return [Vector] The resulting entries.
      def +(other)
        snapshot = internal_vector.snapshot
        appended = if other.equal?(self)
                     snapshot
                   else
                     reusable_operand_snapshot(other) || vector_operand(other).map { derived_storage(it) }
                   end
        build_derived_vector(snapshot + appended)
      end

      # Repeat a snapshot, or join it when a String separator is supplied.
      # @param other [Integer, #to_str] The non-negative repetition count or String separator.
      # @return [Vector, String] The repeated entries, or the joined String for a separator.
      def *(other)
        separator = String.try_convert(other)
        return join(separator) if separator
        build_derived_vector(internal_vector.snapshot * other)
      end

      # Remove values present in another sequence.
      # @param other [Vector, #to_ary] The other sequence.
      # @return [Vector] The resulting entries.
      def -(other) = derive_array_operation(:-, other)

      # Intersect with another sequence.
      # @param other [Vector, #to_ary] The other sequence.
      # @return [Vector] The resulting entries.
      def &(other) = derive_array_operation(:&, other)

      # Union with another sequence.
      # @param other [Vector, #to_ary] The other sequence.
      # @return [Vector] The resulting entries.
      def |(other) = derive_array_operation(:|, other)

      # Remove values present in any supplied sequence.
      # @param others [Array<Vector, #to_ary>] The other sequences.
      # @return [Vector] The resulting entries.
      def difference(*others) = derive_array_operation(:difference, *others)

      # Intersect with every supplied sequence.
      # @param others [Array<Vector, #to_ary>] The other sequences.
      # @return [Vector] The resulting entries.
      def intersection(*others) = derive_array_operation(:intersection, *others)

      # Union with every supplied sequence.
      # @param others [Array<Vector, #to_ary>] The other sequences.
      # @return [Vector] The resulting entries.
      def union(*others) = derive_array_operation(:union, *others)

      # Return whether another sequence shares any value.
      # @param other [Vector, #to_ary] The other sequence.
      # @return [Boolean] Whether the sequences have an entry in common.
      def intersect?(other) = to_a.intersect?(vector_operand(other))

      # Binary-search the live entries and return the matching value.
      # The entries must remain sorted. Concurrent writes can change the result.
      # @yield [value] Test an entry in an already sorted vector. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The entry being tested.
      # @yieldreturn [Boolean, Numeric, nil] A monotonic predicate or comparison result, following Array's binary-search
      #   contract.
      # @return [BasicObject, nil, Enumerator] The matching entry, nil if absent, or an Enumerator.
      def bsearch
        return enum_for(__method__) { size } unless block_given?

        candidate = nil
        index = (0...size).bsearch do |position|
          value = self[position]
          result = yield(value)
          candidate = value if result.equal?(true) || (result.is_a?(Numeric) && result.zero?)
          result
        end
        candidate if index
      end

      # Binary-search the live entries and return the matching index.
      # The entries must remain sorted. Concurrent writes can change the result.
      # @yield [value] Test an entry in an already sorted vector. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The entry being tested.
      # @yieldreturn [Boolean, Numeric, nil] A monotonic predicate or comparison result, following Array's binary-search
      #   contract.
      # @return [Integer, nil, Enumerator] The matching index, nil if absent, or an Enumerator.
      def bsearch_index
        return enum_for(__method__) { size } unless block_given?

        (0...size).bsearch { yield self[it] }
      end

      # Pack a logical snapshot according to format.
      # @overload pack(format, buffer: nil)
      #   @param format [String] The Array packing directives.
      #   @param buffer [String, nil] An optional String to append the packed bytes to.
      #   @return [String] The packed bytes, using buffer when supplied.
      def pack(format, **) = to_a.pack(format, **)

      # Select values matched by pattern, optionally transforming them.
      # @param pattern [#===] The pattern used to test each entry.
      # @yield [value] Optionally transform each selected entry.
      # @yieldparam value [BasicObject] The selected entry.
      # @yieldreturn [BasicObject] The replacement value.
      # @return [Vector] The selected entries or their block results.
      def grep(pattern, &)
        snapshot = internal_vector.snapshot
        logical  = snapshot.map { logical_value(it) }
        result   = block_given? ? logical.grep(pattern, &) : logical.grep(pattern)
        build_derived_from_logical(result, snapshot, logical)
      end

      # Select values not matched by pattern, optionally transforming them.
      # @param pattern [#===] The pattern used to test each entry.
      # @yield [value] Optionally transform each selected entry.
      # @yieldparam value [BasicObject] The selected entry.
      # @yieldreturn [BasicObject] The replacement value.
      # @return [Vector] The selected entries or their block results.
      def grep_v(pattern, &)
        snapshot = internal_vector.snapshot
        logical  = snapshot.map { logical_value(it) }
        result   = block_given? ? logical.grep_v(pattern, &) : logical.grep_v(pattern)
        build_derived_from_logical(result, snapshot, logical)
      end

      # Split live entries into accepted and rejected Vectors, wrapped in a Vector.
      # @yield [value] Classify each entry. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] A truthy value for the accepted group, or a falsy value for the rejected group.
      # @return [Vector, Enumerator] A Vector containing the accepted and rejected Vectors, or an Enumerator.
      def partition
        return enum_for(__method__) { size } unless block_given?

        accepted, rejected = internal_vector.each.partition { yield logical_value(it) }
        build_derived_values([build_derived_vector(accepted), build_derived_vector(rejected)])
      end

      # Group live entries into same-kind Vectors.
      # @yield [value] Compute a grouping key. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The key for the entry's group.
      # @return [Hash{BasicObject => Vector}, Enumerator] Keys mapped to same-kind Vector groups, or an Enumerator.
      def group_by
        return enum_for(__method__) { size } unless block_given?

        internal_vector.each.group_by { yield logical_value(it) }
          .transform_values { build_derived_vector(it) }
      end

      # Return minimum and maximum in a Vector.
      # @yield [left, right] Optionally compare two entries. Without a block, uses `<=>`.
      # @yieldparam left [BasicObject] The left entry.
      # @yieldparam right [BasicObject] The right entry.
      # @yieldreturn [Numeric] A negative number, zero, or a positive number for less than, equal to, or greater than.
      # @return [Vector] The minimum and maximum, with two nil entries for an empty vector.
      def minmax(&)
        snapshot = internal_vector.snapshot
        logical  = snapshot.map { logical_value(it) }
        build_derived_from_logical(logical.minmax(&), snapshot, logical)
      end

      # Return one minimum, or a Vector when count is supplied.
      # @param count [Integer, nil] The maximum result size. Omit or pass nil to return one entry.
      # @yield [left, right] Optionally compare two entries. Without a block, uses `<=>`.
      # @yieldparam left [BasicObject] The left entry.
      # @yieldparam right [BasicObject] The right entry.
      # @yieldreturn [Numeric] A negative number, zero, or a positive number for less than, equal to, or greater than.
      # @return [BasicObject, Vector, nil] One extreme entry, nil if empty, or a Vector when count is supplied.
      def min(count = UNDEFINED, &)
        count = normalized_extreme_count(count)
        return super(&) if count.nil?
        return build_derived_vector([]) if count.zero?

        snapshot = internal_vector.snapshot
        logical  = snapshot.map { logical_value(it) }
        build_derived_from_logical(logical.min(count, &), snapshot, logical)
      end

      # Return one maximum, or a Vector when count is supplied.
      # @param count [Integer, nil] The maximum result size. Omit or pass nil to return one entry.
      # @yield [left, right] Optionally compare two entries. Without a block, uses `<=>`.
      # @yieldparam left [BasicObject] The left entry.
      # @yieldparam right [BasicObject] The right entry.
      # @yieldreturn [Numeric] A negative number, zero, or a positive number for less than, equal to, or greater than.
      # @return [BasicObject, Vector, nil] One extreme entry, nil if empty, or a Vector when count is supplied.
      def max(count = UNDEFINED, &)
        count = normalized_extreme_count(count)
        return super(&) if count.nil?
        return build_derived_vector([]) if count.zero?

        snapshot = internal_vector.snapshot
        logical  = snapshot.map { logical_value(it) }
        build_derived_from_logical(logical.max(count, &), snapshot, logical)
      end

      # Return one block minimum, or a Vector when count is supplied.
      # @param count [Integer, nil] The maximum result size. Omit or pass nil to return one entry.
      # @yield [value] Compute a comparison key. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The key used to order the entry.
      # @return [BasicObject, Vector, nil, Enumerator] One extreme entry, nil if empty, a Vector for count, or an
      #   Enumerator.
      def min_by(count = UNDEFINED)
        count = normalized_extreme_count(count)
        unless block_given?
          return enum_for(__method__) { size } if count.nil? # rubocop:disable Lint/ToEnumArguments
          return enum_for(__method__, count) { size }
        end
        return super() { yield it } if count.nil?
        return build_derived_vector([]) if count.zero?

        snapshot = internal_vector.snapshot
        logical  = snapshot.map { logical_value(it) }
        build_derived_from_logical(logical.min_by(count) { yield it }, snapshot, logical)
      end

      # Return one block maximum, or a Vector when count is supplied.
      # @param count [Integer, nil] The maximum result size. Omit or pass nil to return one entry.
      # @yield [value] Compute a comparison key. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The key used to order the entry.
      # @return [BasicObject, Vector, nil, Enumerator] One extreme entry, nil if empty, a Vector for count, or an
      #   Enumerator.
      def max_by(count = UNDEFINED)
        count = normalized_extreme_count(count)
        unless block_given?
          return enum_for(__method__) { size } if count.nil? # rubocop:disable Lint/ToEnumArguments
          return enum_for(__method__, count) { size }
        end
        return super() { yield it } if count.nil?
        return build_derived_vector([]) if count.zero?

        snapshot = internal_vector.snapshot
        logical  = snapshot.map { logical_value(it) }
        build_derived_from_logical(logical.max_by(count) { yield it }, snapshot, logical)
      end

      # Return the block minimum and maximum in a Vector.
      # @yield [value] Compute a comparison key. Returns an Enumerator without a block.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The key used to order the entry.
      # @return [Vector, Enumerator] The minimum and maximum entries, two nil entries if empty, or an Enumerator.
      def minmax_by
        return enum_for(__method__) { size } unless block_given?

        snapshot = internal_vector.snapshot
        logical  = snapshot.map { logical_value(it) }
        build_derived_from_logical(logical.minmax_by { yield it }, snapshot, logical)
      end

      # Yield same-kind windows from live iteration.
      # @param count [Integer] The positive window size.
      # @yield [window] Visit each window. Returns an Enumerator without a block.
      # @yieldparam window [Vector] The current window.
      # @yieldreturn [void] The result is ignored.
      # @return [self, Enumerator]
      def each_slice(count)
        count = convert_vector_count(count)
        raise ArgumentError, "invalid slice size" unless count.positive?
        return enum_for(__method__, count) { (size + count - 1) / count } unless block_given?

        internal_vector.each.each_slice(count) { yield build_derived_vector(it) }
        self
      end

      # Yield same-kind overlapping windows from live iteration.
      # @param count [Integer] The positive window size.
      # @yield [window] Visit each window. Returns an Enumerator without a block.
      # @yieldparam window [Vector] The current window.
      # @yieldreturn [void] The result is ignored.
      # @return [self, Enumerator]
      def each_cons(count)
        count = convert_vector_count(count)
        raise ArgumentError, "invalid size" unless count.positive?
        return enum_for(__method__, count) { [size - count + 1, 0].max } unless block_given?

        internal_vector.each.each_cons(count) { yield build_derived_vector(it) }
        self
      end

      # Group adjacent entries by a block-generated key. Group contents are Vectors.
      # @yield [value] Compute a grouping key for each entry.
      # @yieldparam value [BasicObject] The current value.
      # @yieldreturn [BasicObject] The grouping key. Nil and `:_separator` omit the entry. `:_alone` isolates it.
      # @return [Enumerator] Yields keys and Vector groups. Without a block, enumerates the grouping operation.
      def chunk(&block)
        return enum_for(__method__) { size } unless block

        Enumerator.new do |yielder|
          snapshot = internal_vector.snapshot
          snapshot.chunk { block.call(logical_value(it)) }.each do |key, group|
            yielder.yield(key, build_derived_vector(group))
          end
        end
      end

      # Group adjacent entries while the block accepts each pair.
      # @yield [left, right] Test consecutive entries. A block is required.
      # @yieldparam left [BasicObject] The preceding entry.
      # @yieldparam right [BasicObject] The current entry.
      # @yieldreturn [BasicObject] A truthy value to keep the entries in one group.
      # @return [Enumerator] Yields same-kind Vector groups.
      def chunk_while(&block)
        raise ArgumentError, "no block given" unless block

        Enumerator.new do |yielder|
          snapshot = internal_vector.snapshot
          snapshot.chunk_while { |left, right| block.call(logical_value(left), logical_value(right)) }
            .each { yielder << build_derived_vector(it) }
        end
      end

      # Group a snapshot before matching entries.
      # @param arguments [Array<BasicObject>] One pattern for `===` matching, or no arguments when using a block.
      # @yield [value] Test each entry when no pattern is supplied.
      # @yieldparam value [BasicObject] The current entry.
      # @yieldreturn [BasicObject] A truthy value to split at this entry.
      # @return [Enumerator] Yields same-kind Vector groups.
      def slice_before(*arguments, &block)
        logical_grouping_enumerator(:slice_before, arguments, block)
      end

      # Group a snapshot after matching entries.
      # @param arguments [Array<BasicObject>] One pattern for `===` matching, or no arguments when using a block.
      # @yield [value] Test each entry when no pattern is supplied.
      # @yieldparam value [BasicObject] The current entry.
      # @yieldreturn [BasicObject] A truthy value to split at this entry.
      # @return [Enumerator] Yields same-kind Vector groups.
      def slice_after(*arguments, &block)
        logical_grouping_enumerator(:slice_after, arguments, block)
      end

      # Group a snapshot between pairs accepted by the block.
      # @yield [left, right] Test consecutive entries. A block is required.
      # @yieldparam left [BasicObject] The preceding entry.
      # @yieldparam right [BasicObject] The current entry.
      # @yieldreturn [BasicObject] A truthy value to start a new group.
      # @return [Enumerator] Yields same-kind Vector groups.
      def slice_when(&block)
        raise ArgumentError, "no block given" unless block
        logical_grouping_enumerator(:slice_when, [], block)
      end

      # Zip values into Vector rows. With a block, yield rows and return nil.
      # @param others [Array<Enumerable, #to_ary>] The sequences to combine with this vector.
      # @yield [row] Optionally visit each combined row.
      # @yieldparam row [Vector] One entry from each sequence, padded with nil for shorter sequences.
      # @yieldreturn [void] The result is ignored.
      # @return [Vector, nil] A Vector of Vector rows, or nil when a block is supplied.
      def zip(*others)
        snapshot = internal_vector.snapshot
        operands = others.map do |other|
          stored = other.equal?(self) ? snapshot : reusable_operand_snapshot(other)
          stored ? [stored, true] : [zip_operand(other, snapshot.length), false]
        end
        build_row = lambda do |stored, index|
          row = [stored]
          operands.each do |values, prepared|
            row << (prepared ? values[index] : derived_storage(values[index]))
          end
          build_derived_vector(row)
        end
        if block_given?
          snapshot.each_with_index { |stored, index| yield build_row.call(stored, index) }
          nil
        else
          rows = snapshot.each_with_index.map { |stored, index| build_row.call(stored, index) }
          build_derived_values(rows)
        end
      end

      # Materialize enumeration as a Vector rather than an Array.
      # @return [Vector] A new same-kind Vector containing the result.
      def entries = build_derived_vector(internal_vector.snapshot)

      # Read an index without waiting for atomic-update access, or return a slice snapshot.
      # @param index [Integer, Range] The index, start index, or range. Negative indexes count from the end.
      # @param length [Integer] The slice length. Omit for a single index or range.
      # @return [BasicObject, Vector, nil] The logical value, a slice Vector, or nil if absent.
      def [](index, length = UNDEFINED)
        return internal_vector[index] if length.equal?(UNDEFINED) && !index.is_a?(Range)
        slice(index, length)
      end

      # Store a value or replace a slice atomically, growing the vector if necessary.
      # Slice replacements accept a Vector, Array-like object, or one scalar value.
      # @param index [Integer, Range] The index, start index, or range.
      # @param value [BasicObject, Integer] The assigned value, or the slice length for three arguments.
      # @param replacement [BasicObject] The replacement for the three-argument form.
      # @return [BasicObject] The assigned value or replacement sequence.
      def []=(index, value, replacement = UNDEFINED)
        if replacement.equal?(UNDEFINED) && !index.is_a?(Range)
          internal_vector[index] = value
        else
          assign_vector_slice(index, value, replacement)
        end
      end

      # Read an index after acquiring atomic-update access.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @return [BasicObject, nil] The value, or nil if absent or timed out.
      def get(index, timeout: nil) = internal_vector.get(index, timeout:)

      # Store a value after acquiring atomic-update access.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @param value [BasicObject] The value to store.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @return [BasicObject, false] The value, or false on timeout.
      def store(index, value, timeout: nil) = internal_vector.store(index, value, timeout:)

      # Append values atomically. Calls with one value use the scalar backend path.
      # @param value [BasicObject] The first value. Omit to leave contents unchanged.
      # @param rest [Array<BasicObject>] Additional values to append.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @return [self, false] Self on success, or false on timeout.
      def push(value = UNDEFINED, *rest, timeout: nil)
        if rest.empty? && !value.equal?(UNDEFINED)
          backend = internal_vector
          completed = timeout.nil? ? backend.push(value) : backend.push(value, timeout:)
          return completed ? self : false
        end
        push_values(value.equal?(UNDEFINED) ? rest : [value, *rest], timeout:)
      end

      # Append snapshots of one or more sequences and return this vector.
      # Each append is synchronized separately. Other writers may interleave.
      # Values use the vector's default transfer mode. Self-concatenation reuses
      # existing storage and captures the original contents only once.
      # @param sources [Array<Vector, #to_ary>] sequences to append
      # @return [self]
      def concat(*sources)
        Internal::Freeze.check(self)
        own_snapshot = internal_vector.snapshot if sources.any? { it.equal?(self) }
        snapshots = sources.map do |source|
          if source.equal?(self)
            own_snapshot
          else
            reusable_operand_snapshot(source) || vector_operand(source).map { derived_storage(it) }
          end
        end
        snapshots.each { |values| values.each { internal_vector.push(it) } }
        self
      end

      # Append a single value without a timeout.
      # @param value [BasicObject] The value to append.
      # @return [self]
      def <<(value) = push(value)

      # Append values using the same options as {#push}.
      # @overload append(*values, timeout: nil)
      #   @param values [Array<BasicObject>] The values to append.
      #   @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      #   @return [self, false] Self on success, or false on timeout.
      def append(...) = push(...)

      # Remove and return the last value, or a Vector of the last count values, atomically.
      # This does not wait for an empty vector to become nonempty.
      # @param count [Integer] The maximum number of values. Omit to return one value.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @return [BasicObject, Vector, nil] Removed values, or nil if empty without a count or timed out.
      def pop(count = UNDEFINED, timeout: nil)
        if count.equal?(UNDEFINED)
          backend = internal_vector
          return timeout.nil? ? backend.pop : backend.pop(timeout:)
        end
        pop_values(count, timeout:)
      end

      # Remove the first entry, or the first count entries, atomically.
      # @param count [Integer] The maximum number of entries. Omit to return one entry.
      # @return [BasicObject, Vector, nil] The first entry, nil if empty, or a Vector of removed entries.
      def shift(count = UNDEFINED)
        result = mutate_vector { count.equal?(UNDEFINED) ? it.shift : it.shift(count) }
        count.equal?(UNDEFINED) ? logical_value(result) : build_derived_vector(result)
      end

      # Prepend values atomically using the vector's default transfer mode.
      # @param values [Array<BasicObject>] The values to prepend.
      # @return [self]
      def unshift(*values)
        mutate_vector { it.unshift(*values.map { derived_storage(it) }) }
        self
      end
      alias prepend unshift

      # Insert values before an index atomically. Negative indexes count from the end.
      # @param index [Integer] The insertion index. -1 appends values.
      # @param values [Array<BasicObject>] The values to insert.
      # @return [self]
      def insert(index, *values)
        mutate_vector { it.insert(index, *values.map { derived_storage(it) }) }
        self
      end

      # Remove the entry at an index and shift later entries left atomically.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @return [BasicObject, nil] The removed logical value, or nil if absent.
      def delete_at(index) = logical_value(mutate_vector { it.delete_at(index) })

      # Remove a range of entries atomically.
      # @param index [Integer, Range] The index, start index, or range.
      # @param length [Integer] The number of entries. Omit for a single index or range.
      # @return [BasicObject, Vector, nil] The removed entry, a Vector of removed entries, or nil if absent.
      def slice!(index, length = UNDEFINED)
        result = mutate_vector { length.equal?(UNDEFINED) ? it.slice!(index) : it.slice!(index, length) }
        return if result.nil?
        length.equal?(UNDEFINED) && !index.is_a?(Range) ? logical_value(result) : build_derived_vector(result)
      end

      # Replace all entries atomically with the contents of another sequence.
      # @param source [Vector, #to_ary] The replacement sequence.
      # @return [self]
      def replace(source)
        mutate_vector { |values| values.replace(source.equal?(self) ? values : operand_storage(source)) }
        self
      end

      # Fill all or part of the vector atomically, growing it when necessary.
      # The block must not write to this vector.
      # @overload fill(value, start = 0, length = size)
      #   @param value [BasicObject] The fill value.
      #   @param start [Integer, Range] The start index or range.
      #   @param length [Integer] The number of entries to fill.
      # @overload fill(start = 0, length = size) { |index| ... }
      #   @param start [Integer, Range] The start index or range.
      #   @param length [Integer] The number of entries to fill.
      #   @yield [index] Compute a value for each filled position.
      #   @yieldparam index [Integer] The current index.
      #   @yieldreturn [BasicObject] The fill value.
      # @return [self]
      def fill(*arguments)
        mutate_vector do |values|
          if block_given?
            values.fill(*arguments) { derived_storage(yield(it)) }
          else
            raise ArgumentError, "wrong number of arguments (given 0, expected 1..3)" if arguments.empty?
            values.fill(derived_storage(arguments.first), *arguments.drop(1))
          end
        end
        self
      end

      # Compare logical entries lexicographically, as with Array.
      # @param other [Vector, #to_ary] The sequence to compare against.
      # @return [Integer, nil] A negative number, zero, a positive number, or nil if incomparable.
      def <=>(other)
        return 0 if equal?(other)
        compare_vector(other)
      end

      # Replace an index and return its previous value, growing the vector if necessary.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @param replacement [BasicObject] The new value.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @return [BasicObject, nil] The previous value, or nil if absent or timed out.
      def swap(index, replacement, timeout: nil) = internal_vector.swap(index, replacement, timeout:)

      # Compute and store a value only when the index is absent or contains nil.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @yield Called without arguments to compute a value when the slot is absent or nil.
      # @yieldreturn [BasicObject] The value to store.
      # @return [BasicObject, nil] The existing or computed value, or nil on timeout.
      def store_if_absent(index, timeout: nil, &) = internal_vector.store_if_absent(index, timeout:, &)

      # Replace an existing index only if its value matches the expected value.
      # This never grows the vector. Matching uses the configured comparison mode.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @param expected [BasicObject] The value that must match the current entry.
      # @param replacement [BasicObject] The value to store on a match.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @return [Boolean] Whether the replacement succeeded. False on timeout.
      def compare_and_set(index, expected, replacement, timeout: nil)
        internal_vector.compare_and_set(index, expected, replacement, timeout:)
      end

      # Atomically replace an index with the block result, growing the vector if necessary.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @yield [value] Compute the replacement while holding atomic-update access.
      # @yieldparam value [BasicObject, nil] The current value, or nil if absent.
      # @yieldreturn [BasicObject] The replacement value.
      # @return [BasicObject, nil] The replacement value, or nil on timeout.
      def update(index, timeout: nil, &) = internal_vector.update(index, timeout:, &)

      # Store initial for an absent or nil index, otherwise replace it with the block result.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @param initial [BasicObject] The value to store when the slot is absent or nil.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @yield [value] Compute a replacement for an existing non-nil entry.
      # @yieldparam value [BasicObject] The current non-nil value.
      # @yieldreturn [BasicObject] The replacement value.
      # @return [BasicObject, nil] The stored value, or nil on timeout.
      def upsert(index, initial, timeout: nil, &) = internal_vector.upsert(index, initial, timeout:, &)

      # Wait until a block condition matches the value at an index.
      # Absent indexes are observed as nil.
      # One timeout budget covers all checks and waits. The block is not interrupted.
      # @yieldparam value [BasicObject, nil] the current value
      # @yieldreturn [Boolean] whether the value matches
      # @param index [Integer] the index to observe. Negative indexes count from the end.
      # @param timeout [Numeric, nil] the total seconds available
      # @return [BasicObject, nil] the matching value, or nil on timeout
      # @raise [LocalJumpError] if no block is given
      def wait_until(index, timeout: nil, &) = Internal.wait_until(self, index, timeout:, &)

      # Wait while the block returns a truthy value.
      # @yieldparam value [BasicObject, nil] the current value
      # @yieldreturn [BasicObject] a truthy value to keep waiting, or nil or false to stop
      # @param index [Integer] the index to observe. Negative indexes count from the end.
      # @param timeout [Numeric, nil] the total seconds available
      # @return [BasicObject, nil] the value when the condition becomes false, or nil on timeout
      # @raise [LocalJumpError] if no block is given
      def wait_while(index, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        wait_until(index, timeout:) { |value| !yield(value) }
      end

      # Wait while `object === value` is true.
      # @param object [#===] the pattern to stop matching
      # @param index [Integer] the index to observe. Negative indexes count from the end.
      # @param timeout [Numeric, nil] the total seconds available
      # @return [BasicObject, nil] the first nonmatching value, or nil on timeout
      def wait_while_match(index, object, timeout: nil)
        wait_while(index, timeout:) { |value| object === value } # rubocop:disable Style/CaseEquality
      end

      # Wait until the current value equals an object using the configured comparison mode.
      # @param object [BasicObject, nil] the value to compare with the current value
      # @param index [Integer] the index to observe. Negative indexes count from the end.
      # @param timeout [Numeric, nil] the total seconds available
      # @return [BasicObject, nil] the matching value, or nil on timeout
      def wait_until_value(index, object, timeout: nil)
        wait_until(index, timeout:) { |value| compare_by_identity? ? object.equal?(value) : object == value }
      end

      # Wait until `object === value` is true.
      # @param object [#===] the pattern to match
      # @param index [Integer] the index to observe. Negative indexes count from the end.
      # @param timeout [Numeric, nil] the total seconds available
      # @return [BasicObject, nil] the matching value, or nil on timeout
      def wait_until_match(index, object, timeout: nil)
        wait_until(index, timeout:) { |value| object === value } # rubocop:disable Style/CaseEquality
      end

      # Wait until an index no longer matches expected. Absent indexes are observed as nil.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @param expected [BasicObject] The value to wait for the entry to stop matching.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @return [BasicObject, nil] The changed value, or nil on timeout.
      def wait_until_changed(index, expected, timeout: nil)
        internal_vector.wait_until_changed(index, expected, timeout:)
      end

      # (see #wait_until_changed)
      def wait_while_value(...) = wait_until_changed(...)

      # Wait until an index contains a non-nil value.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @return [BasicObject, nil] The non-nil value, or nil on timeout.
      def wait_until_non_nil(index, timeout: nil) = internal_vector.wait_until_non_nil(index, timeout:)

      # @return [Integer] The number of slots, including nil slots.
      def size = internal_vector.size

      # @return [Boolean] Whether values are compared by identity.
      def compare_by_identity? = internal_vector.compare_by_identity?

      # @return [Boolean] Whether stored values must be Ractor-shareable.
      def shareable_values? = false

      # Remove all slots.
      # @return [self]
      def clear
        internal_vector.clear
        self
      end

      protected

      def internal_vector = @vector

      # Convert a stored value into the value visible through the public API.
      def logical_value(value) = value

      def deletion_comparison(value) = value

      def deletion_match?(stored, expected)
        compare_by_identity? ? stored.equal?(expected) : array_value_equal?(stored, expected)
      end

      # Build a new same-kind Vector from already prepared stored values.
      def build_derived_vector(values)
        self.class.new(values, compare_by_identity: compare_by_identity?)
      end

      def reusable_operand_snapshot(other)
        return unless other.instance_of?(self.class)
        other.internal_vector.snapshot
      end

      private

      def normalize_vector_source(source) = source.is_a?(Integer) ? Array.new(source) : source

      def mutate_vector(timeout: nil)
        result = nil
        completed = internal_vector.batch_update(timeout:) { |values| result = yield values }
        completed ? result : UNDEFINED
      end

      def push_values(values, timeout: nil, mode: nil)
        result = mutate_vector(timeout:) { it.concat(values.map { prepare_vector_value(it, mode:) }) }
        result.equal?(UNDEFINED) ? false : self
      end

      def prepare_vector_value(value, **) = derived_storage(value)

      def pop_values(count, timeout: nil)
        result = mutate_vector(timeout:) { it.pop(count) }
        build_derived_vector(result) unless result.equal?(UNDEFINED)
      end

      def operand_storage(source)
        reusable_operand_snapshot(source) || vector_operand(source).map { derived_storage(it) }
      end

      def assign_vector_slice(index, value, replacement)
        assigned = replacement.equal?(UNDEFINED) ? value : replacement
        mutate_vector do |values|
          stored = if assigned.equal?(self)
                     values.dup
                   elsif assigned.is_a?(Vector)
                     operand_storage(assigned)
                   else
                     converted = Array.try_convert(assigned)
                     converted ? converted.map { derived_storage(it) } : [derived_storage(assigned)]
                   end
          if replacement.equal?(UNDEFINED)
            values[index] = stored
          else
            values[index, value] = stored
          end
        end
        assigned
      end

      def storage_from_logical(values, source_storage, source_values)
        retained = retained_storage_index(source_storage, source_values)
        values.map { |value| retained.fetch(value) { derived_storage(value) } }
      end

      def retained_storage_index(storage, logical)
        retained = {}.compare_by_identity
        logical.each_with_index { |value, index| retained[value] ||= storage[index] }
        retained
      end

      def sequence_storage(values, retained)
        values.map { |value| retained.fetch(value) { prepare_sequence_value(value) } }
      end

      def prepare_sequence_value(value) = derived_storage(value)

      def sequence_operand(value, retained)
        storage = reusable_operand_snapshot(value) if value.is_a?(Vector)
        return vector_operand(value) unless storage
        logical = storage.map { logical_value(it) }
        logical.each_with_index { |entry, index| retained[entry] ||= storage[index] }
        logical
      end

      def flatten_vector_values(logical, level, retained)
        level = convert_vector_count(level)
        return logical if level.zero?
        seen = {}.compare_by_identity
        expanded = false
        result = []
        stack = [[logical, 0, level, nil]]
        until stack.empty?
          values, index, depth, owner = stack.last
          if index >= values.length
            seen.delete(owner) if owner
            stack.pop
            next
          end
          value = values[index]
          stack.last[1] += 1
          nested = unless depth.zero?
                     value.is_a?(Vector) ? sequence_operand(value, retained) : Array.try_convert(value)
                   end
          unless nested
            result << value
            next
          end
          raise ArgumentError, "tried to flatten recursive array" if seen.key?(value)
          expanded = true
          seen[value] = true
          stack << [nested, 0, depth.negative? ? -1 : depth - 1, value]
        end
        expanded ? result : logical
      end

      def vector_combinations(method, arguments, block)
        return enum_for(method, *arguments) { to_a.public_send(method, *arguments).size } unless block
        snapshot = internal_vector.snapshot
        logical = snapshot.map { logical_value(it) }
        logical.public_send(method, *arguments) { block.call(build_derived_from_logical(it, snapshot, logical)) }
        self
      end

      def compare_vector(other)
        guard = Internal::Storage.fiber.store_if_absent(:farce_vector_comparison) { {}.compare_by_identity }
        peers = (guard[self] ||= {}.compare_by_identity)
        return 0 if peers.key?(other)
        peers[other] = true
        entered = true
        to_a <=> (other.is_a?(Vector) ? other.to_a : other)
      ensure
        if entered
          peers.delete(other)
          guard.delete(self) if peers.empty?
        end
      end

      def each_for_inspect(&) = internal_vector.each(&)

      def build_derived_values(values) = build_derived_vector(values.map { derived_storage(it) })

      def build_derived_from_logical(values, source_storage, source_values)
        build_derived_vector(storage_from_logical(values, source_storage, source_values))
      end

      def derived_storage(value) = value

      def derive_array_operation(operation, *others)
        snapshot = internal_vector.snapshot
        logical = snapshot.map { logical_value(it) }
        result = logical.public_send(operation, *others.map { vector_operand(it) })
        build_derived_from_logical(result, snapshot, logical)
      end

      def vector_operand(value)
        return value.to_a if value.is_a?(Vector)
        converted = Array.try_convert(value)
        return converted if converted
        raise TypeError, "no implicit conversion of #{value.class} into Array"
      end

      def zip_operand(value, length)
        converted = Array.try_convert(value)
        return converted if converted
        raise TypeError, "wrong argument type #{value.class} (must respond to :each)" unless value.respond_to?(:each)

        enumerator = value.to_enum
        Array.new(length) do
          enumerator.next
        rescue StopIteration
          nil
        end
      end

      def normalize_hash_pair(value) = value.is_a?(Vector) ? value.to_a : value

      def find_pair(expected, index)
        each do |value|
          pair = if value.is_a?(Vector)
                   value
                 else
                   Array.try_convert(value)
                 end
          return pair if pair && pair.length > index && array_value_equal?(pair[index], expected)
        end
        nil
      end

      def normalized_extreme_count(count)
        return if count.equal?(UNDEFINED) || count.nil?

        count = convert_vector_count(count)
        raise ArgumentError, "negative size (#{count})" if count.negative?
        count
      end

      def array_value_equal?(left, right) = left.equal?(right) || left == right

      def logical_grouping_enumerator(method, arguments, block)
        # Ask an empty Array to validate argument and block combinations now.
        [].public_send(method, *arguments, &block)
        Enumerator.new do |yielder|
          snapshot = internal_vector.snapshot
          logical = snapshot.map { logical_value(it) }
          logical.public_send(method, *arguments, &block).each do |group|
            yielder << build_derived_from_logical(group, snapshot, logical)
          end
        end
      end

      def convert_vector_count(value)
        return value if value.is_a?(Integer)
        raise TypeError, "no implicit conversion of #{value.class} into Integer" unless value.respond_to?(:to_int)
        converted = value.to_int
        return converted if converted.is_a?(Integer)
        raise TypeError, "can't convert #{value.class} to Integer"
      end

      alias convert_vector_index convert_vector_count

      def initialize_copy(other)
        super
        source = other.internal_vector
        copy   = source.class.new(source.snapshot, compare_by_identity: source.compare_by_identity?)
        if is_a?(Local::Scoped)
          Internal::Storage.scope(scope)[self] = copy
        else
          @vector = copy
        end
      end
    end
  end
end
