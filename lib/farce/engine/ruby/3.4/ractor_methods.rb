# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/ractor_methods"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module RactorMethods
      def shareable_proc(**, &)   = ::Ractor.make_shareable(Farce.rebind(**, &))
      def shareable_lambda(**, &) = ::Ractor.make_shareable(Farce.rebind(**, lambda: true, &))
      def select(...)             = raise "TODO: not implemented"
    end
  end
end
