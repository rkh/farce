# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/engine/shared/weak_atom/base"
require "farce/engine/shared/weak_map/reference"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class UnsharedWeakAtom < WeakAtomBase
      private

      def initialize_storage(value)
        @mutex = Mutex.new
        @reference = UnsharedWeakMapWeakReference.for(value)
      end

      def read_value = @mutex.synchronize { @reference.read.last }

      def write_value(value)
        @mutex.synchronize do
          @reference = UnsharedWeakMapWeakReference.for(value)
          @changes.update { |generation| generation + 1 }
        end
        nil
      end
    end
  end
end
