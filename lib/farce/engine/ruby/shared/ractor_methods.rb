# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module RactorMethods
      Internal.delegate(self, ::Ractor, :[], :[]=, :count, :main?, :make_shareable, :shareable?,
        :store_if_absent)

      if ::Ractor.method(:receive!).parameters.include?(%i[key timeout])
        def receive(timeout: nil)
          if selector = RactorSelector.for_call(::Ractor.current)
            selector.ractor_receive(::Ractor.current, timeout:)
          else
            timeout.nil? ? ::Ractor.receive : ::Ractor.receive(timeout:)
          end
        end
      else
        def receive(timeout: nil)
          selector = RactorSelector.for_call(::Ractor.current)
          selector ||= RactorSelector.current unless timeout.nil?
          selector ? selector.ractor_receive(::Ractor.current, timeout:) : ::Ractor.receive
        end
      end

      def builtin?    = true
      def main_thread = Thread.main
      def shim?       = false
      def threads     = Thread.list
    end
  end
end
