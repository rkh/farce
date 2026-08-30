# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/ruby/shared/ractor_methods"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module RactorMethods
      Internal.delegate(self, ::Ractor, :shareable_proc, :shareable_lambda, :select)
    end
  end
end
