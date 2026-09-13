# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# Common atomic and ordered-container loader for JRuby and TruffleRuby in JVM mode.

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    autoload :Counter,          "farce/engine/jvm/counter"
    autoload :Flag,             "farce/engine/jvm/flag"
    autoload :UnsafeTreeMap,    "farce/engine/jvm/tree_map"
    autoload :PriorityQueue,    "farce/engine/jvm/priority_queue"
    autoload :ShareableTreeMap, "farce/engine/jvm/tree_map"
    autoload :TreeMap,          "farce/engine/jvm/tree_map"
  end
end
