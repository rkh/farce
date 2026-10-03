# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable concurrent map with weak shareable keys and weak values.
  # Entries disappear after a weakly held object is collected.
  #
  # Supported modes are `:raise` (the default), `:make_shareable`, and `:dedup`.
  # Modes apply only to values. Keys must already be shareable.
  #
  # With `:dedup`, retain the canonical result returned by store or update,
  # as it might differ from the input and could be immediately collected.
  # Assignment evaluates to the input rather than the canonical result.
  #
  # @example Publishing a value without retaining it strongly
  #   key      = Object.new.freeze
  #   value    = []
  #   map      = Farce::WeakMap.new(mode: :make_shareable)
  #   map[key] = value
  #   map[key].equal?(value) # => true
  class WeakMap < Farce::Abstract::WeakMap
    include Internal::WeakMapValueModes
    include Shareable::Delegated

    private

    def new_map(**)    = Internal::StrictWeakMap.new(**)
    def freeze_backend = @map
  end

  Internal::KeyNormalizer.prepare_concurrent_class(Internal::StrictWeakMap)
end
