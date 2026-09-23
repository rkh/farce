# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/ractor_methods"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module RactorMethods
      def select(*sources, timeout: nil)
        if selector = RactorSelector.for_call(sources)
          selector.ractor_select(*sources, timeout:)
        else
          timeout.nil? ? ::Ractor.select(*sources) : ::Ractor.select(*sources, timeout:)
        end
      end

      Internal.delegate(self, ::Ractor, :shareable_proc, :shareable_lambda, :current, :main, :new)
    end
  end
end
