# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module RactorMethods
      Internal.delegate(self, ::Ractor, :[], :[]=, :count, :main?, :make_shareable, :receive, :shareable?,
        :store_if_absent)

      def builtin?    = true
      def main_thread = Thread.main
      def shim?       = false
      def threads     = Thread.list
    end
  end
end
