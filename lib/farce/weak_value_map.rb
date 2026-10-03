# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable concurrent map with strong shareable keys and weak values.
  #
  # Supported modes are `:raise` (the default), `:make_shareable`, and `:dedup`.
  # Modes apply only to values. Keys must already be shareable.
  # Entries disappear after a weakly held object is collected.
  #
  # With `:dedup`, retain the canonical result returned by store or update,
  # as it might differ from the input and could be immediately collected.
  # Assignment evaluates to the input rather than the canonical result.
  #
  # @example Publishing a value without retaining it strongly
  #   value        = []
  #   map          = Farce::WeakValueMap.new(mode: :make_shareable)
  #   map[:result] = value
  #   map[:result].equal?(value) # => true
  class WeakValueMap < Farce::Abstract::WeakValueMap
    include Internal::WeakMapValueModes
    include Shareable::Delegated

    private

    def new_map(**)    = Internal::StrictWeakValueMap.new(**)
    def freeze_backend = @map
  end

  Internal::KeyNormalizer.prepare_concurrent_class(Internal::StrictWeakValueMap)
end
