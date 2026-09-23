# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/ractor_methods"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module RactorMethods
      def select(*sources, timeout: nil)
        selector = RactorSelector.for_call(sources)
        selector ||= RactorSelector.current unless timeout.nil?
        selector ? selector.ractor_select(*sources, timeout:) : ::Ractor.select(*sources)
      end

      Internal.delegate(self, ::Ractor, :shareable_proc, :shareable_lambda, :current, :main, :new)
    end
  end
end
