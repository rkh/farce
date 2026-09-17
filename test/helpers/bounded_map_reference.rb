# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Helpers
  # Deliberately simple bounded-map model. Victim selection scans all entries,
  # keeping its implementation independent from the linked production design.
  class BoundedMapReference
    Entry = Data.define(:value, :frequency, :access)
    private_constant :Entry

    attr_reader :max_size

    def initialize(policy, max_size:)
      @policy   = policy
      @max_size = max_size
      @entries  = {}
      @clock    = 0
    end

    def [](key)
      entry = @entries[key]
      return unless entry
      touch(key, entry)
      entry.value
    end

    def []=(key, value)
      unless max_size.zero?
        if (entry = @entries[key])
          touch(key, entry, value:)
        else
          remove_victim if @entries.size >= max_size
          @entries[key] = Entry.new(value:, frequency: 1, access: tick)
        end
      end
      value
    end

    def delete(key) = @entries.delete(key)&.value

    def max_size=(limit)
      remove_victim while @entries.size > limit
      @max_size = limit
    end

    def prune(to:)
      original_size = @entries.size
      remove_victim while @entries.size > to
      original_size - @entries.size
    end

    def shift
      return if @entries.empty?
      key = victim_key
      [key, @entries.delete(key).value]
    end

    def clear = @entries.clear
    def empty? = @entries.empty?
    def key?(key) = @entries.key?(key)
    def size = @entries.size
    def to_h = @entries.transform_values(&:value)

    private

    def tick = @clock += 1

    def touch(key, entry, value: entry.value)
      frequency = @policy == :lfu ? entry.frequency + 1 : entry.frequency
      @entries[key] = Entry.new(value:, frequency:, access: tick)
    end

    def victim_key
      @entries.min_by do |_, entry|
        @policy == :lfu ? [entry.frequency, entry.access] : entry.access
      end&.first
    end

    def remove_victim
      @entries.delete(victim_key)
    end
  end
end
