# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A Ractor-shareable map that keeps entries sorted by key.
  # Transfer modes apply only to values. Keys are stored directly, except that mutable strings become immutable.
  # Values stored through this map's mode manager are automatically unwrapped.
  #
  # @example Keeping copied values in key order
  #   map = Farce::TreeMap.new(mode: :copy)
  #   map[2] = ["draft"]
  #   map[1] = ["published"]
  #
  #   map.values # => [["published"], ["draft"]]
  class TreeMap < Farce::Abstract::TreeMap
    include Shareable

    # @!macro modes
    # @param entries [Hash, Array<Array(BasicObject, BasicObject)>, Abstract::Map, #each, nil]
    #   Optional initial entries for the map.
    # @param mode [Symbol] The default value transfer mode.
    def initialize(entries = nil, mode: :copy, **keyword_entries)
      unless keyword_entries.empty?
        raise ArgumentError, "entries given as both positional and keyword arguments" unless entries.nil?
        entries = keyword_entries
      end
      @manager = ModeManager.new(mode:)
      super(entries)
    end

    # The default transfer mode for values.
    # @return [Symbol]
    def mode = @manager.mode

    # Values are stored in Ractor-shareable representations.
    # @return [true]
    def shareable_values? = true

    private

    def new_tree_map(...) = Internal::StrictTreeMap.new(...)
    def unwrap_value(value) = @manager.unwrap(value)
    def wrap_value(value)   = @manager.wrap(value)
  end
end
