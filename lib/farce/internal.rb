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
    EMPTY_ARRAY    = [].freeze
    INTERRUPT_MASK = { Exception => :never }.freeze
    MAP_KEEP       = Object.new.freeze
    MAP_DELETE     = Object.new.freeze

    # A non-main Ractor cannot call CONFIG.frozen if the main Ractor didn't do so before,
    # as CONFIG is not shareable yet. We don't want to eagerly freeze it, otherwise a user can't change
    # any configuration options after loading Farce.
    #
    # We can't do so via `Farce.on_main`, as creating the MainScheduler already needs the configuration.
    # So we rely on the fact that autoloads run on the main Ractor.
    autoload :FROZEN_CONFIG, "farce/internal/_frozen_config"

    include Autoloads
    extend self

    # @api private
    def marshal_protocol_method?(name) = MarshalSupport.protocol_method?(name)

    # @api private
    def marshal_shareable?(value) = Ractor.shareable?(value)

    # Get the value from an options hash with only the `:self` key, and raise an error if there are any other keys.
    def self_option(options, default = nil)
      new_self = options.key?(:self) ? options.delete(:self) : (block_given? ? yield : default)

      if options.any?
        raise ArgumentError, "unknown keyword: #{options.keys.first.inspect}" if options.size == 1
        raise ArgumentError, "unknown keywords: #{options.keys.map(&:inspect).join(", ")}"
      end

      new_self
    end

    def timeout_deadline(timeout)
      return if timeout.nil?

      timeout = Float(timeout)
      unless timeout.finite? && !timeout.negative?
        raise ArgumentError, "timeout must be a finite, non-negative number or nil"
      end
      Clock.now + timeout
    end

    def remaining_timeout(deadline)
      return unless deadline
      remaining = deadline - Clock.now
      remaining.negative? ? 0 : remaining
    end

    # Repeat with one timeout budget. Even a zero timeout permits the first check.
    def with_timeout(timeout)
      raise LocalJumpError, "no block given" unless block_given?
      deadline = timeout_deadline(timeout)
      loop do
        yield remaining_timeout(deadline), deadline
        return if deadline && Clock.now >= deadline
      end
    end

    def wait_until(receiver, *keys, timeout: nil)
      raise LocalJumpError, "no block given" unless block_given?
      with_timeout(timeout) do |_, deadline|
        current = keys.empty? ? receiver.value : receiver[*keys]
        return current if yield(current)
        receiver.wait_until_changed(*keys, current, timeout: remaining_timeout(deadline)) { return }
      end
    end

    def garbage_collectable?(object)
      case object
      when Integer, Float, Complex, Rational, Symbol, true, false, nil then false
      else true
      end
    end

    def walker_constants(object, inherit) = object.constants(inherit)
    def storage_thread(thread)            = thread
    def prepare_mutable_numeric(_)        = nil
    def prepare_map_access(_klass, _kind) = nil
    def finalize_engine                   = nil

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
