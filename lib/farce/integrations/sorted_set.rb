# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group SortedSet Integration
require "farce" unless defined?(Farce::Abstract)
require "sorted_set"

module Farce
  Farce.dedup.store(::SortedSet)
  Internal::Converter.define(::SortedSet, :SortedSet)
end
