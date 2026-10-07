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

      # (see #to_a)
      def deconstruct = to_a

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

      # Return an element or subsequence without changing the hot path for {#[]}.
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

      # Read an index without waiting for atomic-update access.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @return [BasicObject, nil] The value, or nil for an index outside the vector.
      def [](index) = internal_vector[index]

      # Store a value, growing the vector if necessary.
      # @param index [Integer] The index. Negative indexes count from the end.
      # @param value [BasicObject] The value to store.
      # @return [BasicObject] The assigned value.
      def []=(index, value)
        internal_vector[index] = value
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

      # Append a single value.
      # @param value [BasicObject] The value to append.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @return [self, false] Self on success, or false on timeout.
      def push(value, timeout: nil)
        internal_vector.push(value, timeout:) ? self : false
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

      # Append one value using the same options as {#push}.
      # @overload append(value, timeout: nil)
      #   @param value [BasicObject] The value to append.
      #   @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      #   @return [self, false] Self on success, or false on timeout.
      def append(...) = push(...)

      # Remove and return the last value.
      # This does not wait for an empty vector to become nonempty.
      # @param timeout [Numeric, nil] The maximum wait in seconds. Nil waits indefinitely.
      # @return [BasicObject, nil] The last value, or nil if empty or timed out.
      def pop(timeout: nil) = internal_vector.pop(timeout:)

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

      # Build a new same-kind Vector from already prepared stored values.
      def build_derived_vector(values)
        self.class.new(values, compare_by_identity: compare_by_identity?)
      end

      def reusable_operand_snapshot(other)
        return unless other.instance_of?(self.class)
        other.internal_vector.snapshot
      end

      private

      def each_for_inspect(&) = internal_vector.each(&)

      def build_derived_values(values) = build_derived_vector(values.map { derived_storage(it) })

      def build_derived_from_logical(values, source_storage, source_values)
        retained = {}.compare_by_identity
        source_values.each_with_index { |value, index| retained[value] ||= source_storage[index] }
        storage = values.map do |value|
          retained.fetch(value) { derived_storage(value) }
        end
        build_derived_vector(storage)
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
