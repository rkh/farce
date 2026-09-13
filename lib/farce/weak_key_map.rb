# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A concurrent map with weak shareable keys and strongly retained values.
  # Transfer modes apply only to values. Keys are stored directly.
  # Entries disappear after their keys are collected. A value that references
  # its key, including through an envelope, can keep that key alive.
  #
  # @example Associating mutable metadata with a shareable object
  #   owner      = Object.new.freeze
  #   map        = Farce::WeakKeyMap.new
  #   map[owner] = { visits: 1 }
  #   map.update(owner) { |metadata| { visits: metadata[:visits] + 1 } }
  #   map[owner] # => { visits: 2 }
  #
  #   # The entry can disappear once its key is collected.
  #   owner = nil
  class WeakKeyMap < Abstract::WeakKeyMap
    include Internal::MapValueModes
    include Shareable

    private def new_map(**) = Internal::StrictWeakKeyMap.new(**)
  end
end
