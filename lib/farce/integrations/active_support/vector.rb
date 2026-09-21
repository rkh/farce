# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce"
require "active_support"
require "active_support/core_ext"

module Farce
  module Abstract
    class Vector
      # Return entries starting at position from one snapshot.
      # @param position [Integer] The starting index. Negative indexes count from the end.
      # @return [Vector] The tail, or an empty Vector for an out-of-range position.
      def from(position)
        snapshot = internal_vector.snapshot
        build_derived_vector(snapshot.from(position))
      end

      # Return entries through position from one snapshot.
      # @param position [Integer] The final index. Negative indexes count from the end.
      # @return [Vector] The prefix, or an empty Vector for an out-of-range negative position.
      def to(position) = build_derived_vector(internal_vector.snapshot.to(position))

      # Append entries to a new Vector, flattening argument Arrays by one level.
      # New entries follow the receiver's storage rules and transfer mode.
      # @param elements [Array<BasicObject>] The entries or Arrays of entries to append.
      # @return [Vector] The combined entries.
      def including(*elements) = self + elements.flatten(1)

      # Exclude entries using Array's hash-based difference semantics.
      # @param elements [Array<BasicObject>] Entries to exclude, with Arrays flattened by one level.
      # @return [Vector] The remaining entries.
      def excluding(*elements) = self - elements.flatten(1)
      alias without excluding

      # @return [BasicObject, nil] The second entry, or nil if absent.
      def second = self[1]

      # @return [BasicObject, nil] The third entry, or nil if absent.
      def third = self[2]

      # @return [BasicObject, nil] The fourth entry, or nil if absent.
      def fourth = self[3]

      # @return [BasicObject, nil] The fifth entry, or nil if absent.
      def fifth = self[4]

      # @return [BasicObject, nil] The forty-second entry, or nil if absent.
      def forty_two = self[41]

      # @return [BasicObject, nil] The third entry from the end, or nil if absent.
      def third_to_last = self[-3]

      # @return [BasicObject, nil] The second entry from the end, or nil if absent.
      def second_to_last = self[-2]

      # Copy entries using ActiveSupport's deep-copy rules and the Vector's storage rules.
      # Strict Vectors reject deep copies that are not shareable.
      # @return [Vector] An independent same-kind Vector with deeply copied entries.
      def deep_dup = map(&:deep_dup)

      # @return [Vector] Entries for which `blank?` is false, excluding nil and false.
      def compact_blank = reject(&:blank?)

      # Extract keys from each entry in a snapshot.
      # Extracted values follow the receiver's storage rules and transfer mode.
      # @param keys [Array<BasicObject>] Keys passed to each entry's `[]` method.
      # @return [Vector] Values for one key, or Vector rows for multiple keys.
      def pluck(*keys)
        return map { |entry| entry[keys.first] } unless keys.length > 1
        map { |entry| build_derived_values(keys.map { |key| entry[key] }) }
      end

      # Extract keys from the first entry in a snapshot.
      # @param keys [Array<BasicObject>] Keys passed to the first entry's `[]` method.
      # @return [BasicObject, Vector, nil] One value, a Vector for multiple keys, or nil if empty.
      def pick(*keys)
        snapshot = internal_vector.snapshot
        return if snapshot.empty?
        entry = logical_value(snapshot.first)
        return entry[keys.first] unless keys.length > 1
        build_derived_values(keys.map { |key| entry[key] })
      end

      # Order a snapshot by the keys in series, preserving retained entries.
      # @param key [Symbol, #to_proc] The method or callable used to extract ordering keys.
      # @param series [Array] The desired order of keys.
      # @param filter [Boolean] Whether to omit entries whose keys are absent from series.
      # @return [Vector] The ordered entries. Repeated keys repeat their groups when filtering.
      def in_order_of(key, series, filter: true)
        snapshot = internal_vector.snapshot
        logical = snapshot.map { logical_value(it) }
        result = logical.in_order_of(key, series, filter:)
        build_derived_from_logical(result, snapshot, logical)
      end

      # Find the minimum extracted value without storing intermediate results in a Vector.
      # @param key [Symbol, #to_proc] The method or callable used to extract comparison values.
      # @return [BasicObject, nil] The minimum, or nil if empty.
      def minimum(key) = to_a.minimum(key)

      # Find the maximum extracted value without storing intermediate results in a Vector.
      # @param key [Symbol, #to_proc] The method or callable used to extract comparison values.
      # @return [BasicObject, nil] The maximum, or nil if empty.
      def maximum(key) = to_a.maximum(key)

      # Divide a snapshot into a requested number of Vector groups.
      # @param number [Integer] The number of groups, following ActiveSupport's validation rules.
      # @param fill_with [BasicObject] The padding value. False disables padding.
      # @yield [group] Optionally visit each group after grouping the snapshot.
      # @yieldparam group [Vector] A same-kind Vector containing one group.
      # @yieldreturn [void] The result is ignored.
      # @return [Vector] A Vector of groups, whether or not a block is supplied.
      def in_groups(number, fill_with = nil)
        groups = active_support_groups(:in_groups, number, fill_with)
        result = build_derived_values(groups.map { build_derived_vector(it) })
        result.each { yield it } if block_given?
        result
      end

      # Divide a snapshot into Vector groups with a maximum size.
      # @param number [Integer] The positive group size.
      # @param fill_with [BasicObject] The padding value. False disables padding.
      # @yield [group] Optionally visit each group in the snapshot.
      # @yieldparam group [Vector] A same-kind Vector containing one group.
      # @yieldreturn [void] The result is ignored.
      # @return [Vector, self] Groups without a block. With a block, the padded snapshot or self if padding is disabled.
      def in_groups_of(number, fill_with = nil)
        padding = fill_with != false
        groups = active_support_groups(:in_groups_of, number, fill_with)
        return build_derived_values(groups.map { build_derived_vector(it) }) unless block_given?
        groups.each { yield build_derived_vector(it) }
        padding ? build_derived_vector(groups.flatten(1)) : self
      end

      # Split a snapshot at matching entries, omitting the separators.
      # @param value [BasicObject] The separator compared with `==`, ignored when a block is supplied.
      # @yield [entry] Optionally identify separator entries.
      # @yieldparam entry [BasicObject] The current logical entry.
      # @yieldreturn [BasicObject] A truthy value to split at this entry.
      # @return [Vector] A Vector of Vector groups, including empty groups between adjacent separators.
      def split(value = nil)
        groups = internal_vector.snapshot.split do |stored|
          entry = logical_value(stored)
          block_given? ? yield(entry) : array_value_equal?(entry, value)
        end
        build_derived_values(groups.map { build_derived_vector(it) })
      end

      # Convert a snapshot to ActiveSupport's explicit JSON representation.
      # @param options [Hash, nil] Options passed to each entry's JSON conversion.
      # @return [Array] The JSON-compatible values.
      def as_json(options = nil) = to_a.as_json(options)

      # @return [String] The snapshot's URL parameter representation, joined with slashes.
      def to_param = to_a.to_param

      # @param key [String] The query parameter name.
      # @return [String] The encoded query string for the snapshot.
      def to_query(key) = to_a.to_query(key)

      # Format a snapshot as a sentence using ActiveSupport's connectors and locale.
      # @param options [Hash] Connector and locale options accepted by Array#to_sentence.
      # @return [String] The formatted sentence.
      def to_sentence(options = {}) = to_a.to_sentence(options)

      # Format a snapshot, optionally as a database ID list.
      # @param format [Symbol] Use :db for comma-separated IDs, or :default for Array formatting.
      # @return [String] The formatted snapshot.
      def to_fs(format = :default) = to_a.to_fs(format)
      alias to_formatted_s to_fs

      # Serialize a logical snapshot with ActiveSupport's Array XML conversion.
      # Requires ActiveSupport's optional Builder dependency, as Array#to_xml does.
      # @param options [Hash] XML options, including root, children, builder, and indentation.
      # @yield [builder] Optionally append XML inside a nonempty collection's root element.
      # @yieldparam builder [Builder::XmlMarkup] The XML builder used for serialization.
      # @yieldreturn [void] The result is ignored.
      # @return [String] The generated XML.
      def to_xml(options = {}, &) = to_a.to_xml(options, &)

      # Create ActiveSupport's specialized query wrapper from a logical snapshot.
      # @return [ActiveSupport::ArrayInquirer] An Array wrapper supporting predicate methods.
      def inquiry = to_a.inquiry

      private

      def active_support_groups(method, number, fill_with)
        marker = Object.new
        groups = internal_vector.snapshot.public_send(method, number, fill_with == false ? false : marker)
        stored_fill = UNDEFINED
        groups.each do |group|
          group.map! do |entry|
            next entry unless entry.equal?(marker)
            stored_fill = derived_storage(fill_with) if stored_fill.equal?(UNDEFINED)
            stored_fill
          end
        end
        groups
      end
    end
  end
end
