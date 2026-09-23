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

      def select(*sources, timeout: nil, **)
        selector = RactorSelector.for_call(sources)
        selector ||= RactorSelector.current unless timeout.nil? && sources.all?(::Ractor)
        selector ? selector.ractor_select(*sources, timeout:, **) : ::Ractor.select(*sources, **)
      end

      # TODO: Wrapper/Extension to add #default_port, etc.
      def new(...) = ::Ractor.new(...)
      def current  = ::Ractor.current
      def main     = ::Ractor.main
    end
  end
end
