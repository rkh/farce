# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group Oj Integration
require "farce"
require "oj" unless defined?(Oj::VERSION)

require "json" unless [].respond_to?(:to_json)
require_relative "shared/to_json"

module Farce
  # Object-mode reconstruction for Oj.
  # @api private
  module Oj
    # @api private
    Constructor = Data.define(:klass, :options, :counter) do
      def call(value, current = nil)
        object = klass.new(value, **options)
        object.value = current if counter
        object
      end
    end
    private_constant :Constructor

    extend self

    # Register a concrete class for Oj object-mode round trips.
    # Registrations are process-global. Configure them before starting concurrent serialization.
    # Repeated registration replaces the previous reconstruction settings for the class.
    # Source settings are replaced by the supplied options. Counters retain their initial value.
    # Constructor options are copied and made Ractor-shareable.
    # Reading move-backed contents can transfer ownership to the serializing Ractor.
    # @param klass [Class] A named Farce vector, map, set, counter, flag, or atom class.
    # @param options [Hash{Symbol => Object}] Constructor options for restored objects.
    # @return [Class] The registered class.
    # @raise [ArgumentError] If the class is unsupported or anonymous.
    # @raise [Ractor::IsolationError] If registration is attempted outside the main native Ractor.
    # @!scope class
    def register_type(klass, **options)
      if Internal.native_ractors? && !Ractor.main?
        raise Ractor::IsolationError, "register Oj types in the main Ractor before concurrent use"
      end
      unless klass.is_a?(Class) && klass.name && !klass.name.start_with?("Farce::Abstract::")
        raise ArgumentError, "expected a named concrete Farce class"
      end

      reader = if klass <= Abstract::Vector || klass <= Abstract::Set
                 :to_a
               elsif klass <= Abstract::Map
                 :to_h
               elsif klass <= Abstract::Counter || klass <= Abstract::Flag || klass <= Abstract::Atom
                 :value
               else
                 raise ArgumentError, "unsupported Farce class: #{klass}"
               end
      counter = klass <= Abstract::Counter
      constructor = Constructor.new(klass, Ractor.make_shareable(options, copy: true), counter)
      Ractor.make_shareable(constructor)
      members = counter ? [:initial, reader] : [reader]
      ::Oj.register_odd(klass, constructor, :call, *members)
      klass
    end
  end
end

[Farce::Vector, Farce::Map, Farce::Set, Farce::Counter, Farce::Flag, Farce::Atom].each do |klass|
  Farce::Oj.register_type(klass)
end
