# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A concurrent map with direct shareable keys and strongly retained values.
  # Transfer modes apply only to values. Keys are never copied or wrapped.
  # Values stored through this map's mode manager are automatically unwrapped.
  # Updates on different keys can run concurrently.
  # Clearing the map invalidates unfinished updates so they cannot restore removed entries.
  #
  # @example Atomically updating a value
  #   map = Farce::Map.new({ count: 0 })
  #   map.update(:count) { |count| count + 1 } # => 1
  #
  # @example Automatically making values shareable
  #   map = Farce::Map.new(mode: :make_shareable)
  #   map[:jobs] = []
  #   map.update(:jobs) { |items| items + [:job] } # => [:job]
  #   map[:jobs] # => [:job]
  #   Ractor.shareable?(map[:jobs]) # => true
  class Map < Abstract::ConcurrentMap
    include Internal::MapValueModes
    include Shareable

    private def new_map(**) = Internal::StrictMap.new(**)
  end
end
