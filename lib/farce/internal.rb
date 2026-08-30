# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/internal/autoloads"
require "timeout"

experimental = Warning[:experimental]

# simplecov:disable
begin
  Warning[:experimental] = false
  IO::Buffer.new(0) if defined?(IO::Buffer)
  Ractor.new {} if defined?(Ractor) # rubocop:disable Lint/EmptyBlock
ensure
  Warning[:experimental] = experimental
end
# simplecov:enable

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    include Autoloads
    extend self

    # Get the value from an options hash with only the `:self` key, and raise an error if there are any other keys.
    def self_option(options, default = nil)
      new_self = options.key?(:self) ? options.delete(:self) : (block_given? ? yield : default)

      if options.any?
        raise ArgumentError, "unknown keyword: #{options.keys.first.inspect}" if options.size == 1
        raise ArgumentError, "unknown keywords: #{options.keys.map(&:inspect).join(", ")}"
      end

      new_self
    end

    def garbage_collectable?(object)
      case object
      when Integer, Float, Complex, Rational, Symbol, true, false, nil then false
      else true
      end
    end

    def delegate(from, to, *methods)
      methods.each do |method|
        if to.is_a?(Module)
          name  = to.name
          const = Object.const_get(name, false) if name && Object.const_defined?(name, false)
          to    = "::#{name}" if const.equal?(to)
        end

        if to.is_a?(String) || to.is_a?(Symbol)
          from.class_eval <<-RUBY, __FILE__, __LINE__ + 1
            # simplecov:disable
            def #{method}(...)
              #{to}.#{method}(...)
            end
            # simplecov:enable
          RUBY
        else
          from.define_method(method) do |*args, **kwargs, &block|
            to.send(method, *args, **kwargs, &block)
          end
        end
      end
    end
  end
end
