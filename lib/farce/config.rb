# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "farce/internal/autoloads"

# Checks against RUBY_ENGINE, RUBY_VERSION, RUBY_PLATFORM, and ENV are explicitly allowed in this file.
# Checks against RUBY_ENGINE and similar should be avoided within lib outside this file, lib/farce/engine,
# and the one require in lib/farce.rb
# Checks against ENV should be avoided entirely within lib outside of this file
#-

module Farce
  # Configuration for Farce. Will be frozen by Farce once it is accessed, to prevent accidental changes and make it
  # shareable across Ractors.
  #
  # ```ruby
  # require "farce"
  #
  # Farce.config do |c|
  #   c.fiber_scheduler = :select
  # end
  # ```
  class Config
    # Automatically load integrations when their dependencies are loaded. Defaults to true.
    # Can also be set via `FARCE_AUTOLOAD_INTEGRATIONS` (`true`/`false` or `1`/`0`).
    # Set before requiring Farce to also disable startup integration loading.
    # @return [Boolean]
    attr_reader :autoload_integrations

    # Maximum workers in a pool created on the main Ractor. Workers start lazily.
    # Can also be set via `FARCE_MAIN_THREAD_POOL_SIZE`. Defaults to 4.
    attr_reader :main_thread_pool_size

    # Maximum workers in a pool created on another Ractor. Workers start lazily.
    # Can also be set via `FARCE_ADDITIONAL_THREAD_POOL_SIZE`. Defaults to 2.
    attr_reader :additional_thread_pool_size

    # @yield [config] block to modify the configuration
    # @yieldparam config [Config] the configuration object to configure
    def initialize
      yield self if block_given?
      self.autoload_integrations = ENV.fetch("FARCE_AUTOLOAD_INTEGRATIONS", true) if autoload_integrations.nil?
      self.fiber_scheduler       = ENV["FARCE_FIBER_SCHEDULER"] unless instance_variable_defined?(:@fiber_scheduler)
      self.main_thread_pool_size       ||= ENV.fetch("FARCE_MAIN_THREAD_POOL_SIZE", 4)
      self.additional_thread_pool_size ||= ENV.fetch("FARCE_ADDITIONAL_THREAD_POOL_SIZE", 2)
    end

    # @api private
    def marshal_dump
      [1, autoload_integrations, fiber_scheduler, main_thread_pool_size, additional_thread_pool_size, frozen?]
    end

    # @api private
    def marshal_load(data)
      autoload, scheduler, main_size, additional_size, frozen = Internal::MarshalSupport.payload(data, 5)

      self.autoload_integrations        = autoload
      self.fiber_scheduler              = scheduler
      self.main_thread_pool_size        = main_size
      self.additional_thread_pool_size  = additional_size
      freeze if frozen
    end

    # Enable or disable automatic integration loading. Already loaded integrations remain active.
    # @param value [Boolean, String] true, false, or their environment variable representations.
    # @raise [ArgumentError] If the value is not a supported boolean.
    def autoload_integrations=(value)
      @autoload_integrations = case value
                               when true, "true",   "1" then true
                               when false, "false", "0" then false
                               else raise ArgumentError, "autoload_integrations must be a boolean"
                               end
    end

    # Default fiber scheduler for Pool and Scheduler.
    # Explicit constructor blocks override it.
    #
    # Uses `FARCE_FIBER_SCHEDULER` unless assigned explicitly, including an explicit nil.
    #
    # Built-in choices are `:auto`, `:native`, `:jvm`, `:select`, `:kqueue`, `:epoll`,
    # `:io_uring`, and `:nio`. Strings are also accepted. `nil` or an empty string are treated like `:auto`.
    #
    # Other names resolve constants, such as `carbon_fiber` to `CarbonFiber`.
    # If the constant is not defined, it attempts to require the corresponding file.
    # Modules must define their own `Scheduler` class.
    #
    # Classes are constructed without arguments in each worker. Procs must be shareable.
    # Custom schedulers must support the executor used by the Pool or Scheduler.
    #
    # @return [Symbol, Class, Proc] normalized choice
    def fiber_scheduler(&constructor)
      self.fiber_scheduler = constructor if constructor
      @fiber_scheduler
    end

    # Sets the default scheduler. Use `config.fiber_scheduler { MyScheduler.new }`
    # or assign a proc to configure construction. Invalid assignments preserve the old value.
    def fiber_scheduler=(value)
      raise FrozenError, "can't modify frozen Config" if frozen?
      @fiber_scheduler = normalize_fiber_scheduler(value)
    end

    # Implementation used by Farce's built-in scheduler.
    # @return [Symbol] one of `:native`, `:select`, or `:jvm`
    def fiber_scheduler_implementation
      case @fiber_scheduler
      when :native, :jvm, :select     then @fiber_scheduler
      when :kqueue, :epoll, :io_uring then :native
      when :nio                       then :jvm
      else detected_fiber_scheduler_implementation
      end
    end

    # IO backend used by the built-in scheduler. Explicit `backend:` options override it.
    # Availability is checked when a scheduler is created.
    # @return [Symbol] the configured backend or `:auto`
    def io_backend
      case @fiber_scheduler
      when :kqueue, :epoll, :io_uring, :nio, :select then @fiber_scheduler
      else :auto
      end
    end

    # Constructor for a custom scheduler, or nil for the built-in scheduler.
    # @api private
    def fiber_scheduler_constructor
      case @fiber_scheduler
      when Class
        require "farce" unless Farce.const_defined?(:Ractor, false)
        Ractor.shareable_proc(self: @fiber_scheduler) { new }
      when Proc then @fiber_scheduler
      end
    end

    # Sets a positive worker limit for pools created on the main Ractor.
    def main_thread_pool_size=(value)
      @main_thread_pool_size = normalize_thread_pool_size(value)
    end

    # Sets a positive worker limit for pools created on other Ractors.
    def additional_thread_pool_size=(value)
      @additional_thread_pool_size = normalize_thread_pool_size(value)
    end

    # Called internally once the configuration is applied.
    def freeze
      return self if frozen?
      super # need to call this first to avoid infinite recursion in the next line
      ::Ractor.make_shareable(self) if defined?(::Ractor.make_shareable)
      self
    end

    private

    def normalize_thread_pool_size(value)
      size = value.is_a?(String) ? Integer(value, 10) : value
      raise ArgumentError, "thread pool size must be a positive integer" unless size.is_a?(Integer) && size.positive?
      size
    end

    def normalize_fiber_scheduler(value, original = value)
      case value
      when nil, "", "auto", :auto
        return :auto

      when :native, :jvm, :select, :kqueue, :epoll, :io_uring, :nio, Class
        return value

      when "native", "jvm", "select", "kqueue", "epoll", "io_uring", "nio"
        return value.to_sym

      when Symbol, String
        constant = Internal::Autoloads.inflect(value.to_s)
        path     = original.to_s if original.is_a?(String) || original.is_a?(Symbol)

        begin
          require path if path && !Object.const_defined?(constant)
        rescue LoadError => e
          raise e unless e.path == path
        end

        value = Object.const_get(constant)
        return normalize_fiber_scheduler(value, original) if value.is_a?(Module) || value.is_a?(Proc)

      when Module
        if value.const_defined?(:Scheduler, false)
          scheduler = value.const_get(:Scheduler, false)
          return scheduler if scheduler.is_a?(Class)
        end

      when Proc
        require "farce" unless Farce.const_defined?(:Ractor, false)
        return Ractor.shareable?(value) ? value : Ractor.shareable_proc(&value)
      end

      raise ArgumentError, "invalid fiber scheduler: #{value.inspect}"
    rescue NameError => e
      raise ArgumentError, "unknown fiber scheduler: #{original.inspect} (#{e.message})"
    end

    def detected_fiber_scheduler_implementation
      case RUBY_ENGINE
      when "ruby"  then RUBY_PLATFORM.match?(/linux|darwin|bsd/) ? :native : :select
      when "jruby" then :jvm
      else :select
      end
    end
  end

  # shareable_constant_value: none
  CONFIG = Config.new
  private_constant :CONFIG

  def self.config
    yield CONFIG if block_given?
    CONFIG
  end
end
