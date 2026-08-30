# frozen_string_literal: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    class ConstMissing < Module
      module None
        def self.const_missing(_) = self
        def self.===(_) = false
      end

      def initialize(namespace, ignore: nil)
        @namespace = namespace
        @ignore    = Set[*ignore] if ignore
        @mutex     = Mutex.new
        namespace.constants.each do |const|
          next if @ignore&.include?(const) || namespace.autoload?(const)
          const_set(const, namespace.const_get(const))
        end
        super()
      end

      def ===(_) = false

      def const_missing(name)
        return None if @ignore&.include?(name) || !@namespace.const_defined?(name)
        value = @namespace.const_get(name)
        @mutex.synchronize { const_set(name, value) unless const_defined?(name) } if Ractor.main?
        value
      end
    end
  end
end
