# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group SortedSet Integration
require "farce"
require "sorted_set"

module Farce
  Internal::Converter.define(::SortedSet, :SortedSet)
end
