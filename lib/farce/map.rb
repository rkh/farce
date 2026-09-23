# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A concurrent map with direct shareable keys and strongly retained values.
  # Transfer modes apply only to values. String keys use their frozen unary-minus form,
  # except when comparing keys by identity. Other keys must already be shareable.
  # Values stored through this map's mode manager are automatically unwrapped.
  # Updates on different keys can run concurrently.
  #
  # Clearing the map invalidates unfinished updates so they cannot restore removed entries.
  #
  # `dup` and `clone` copy entries into independent storage while sharing stored values.
  # Move-mode envelopes keep their ownership across copies. `dup` and ordinary `clone`
  # remain Ractor-shareable.
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
    include Shareable::Delegated

    private

    def new_map(**)    = Internal::StrictMap.new(**)
    def freeze_backend = @map

    Internal.prepare_map_access(self, :modes)
  end

  Internal::KeyNormalizer.prepare_concurrent_class(Internal::StrictMap)
end
