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
    # Set before requiring Farce to disable startup integration loading and require hooks.
    # @return [Boolean]
    attr_reader :autoload_integrations

    # Maximum workers in a pool created on the main Ractor. Workers start lazily.
    # Can also be set via `FARCE_MAIN_THREAD_POOL_SIZE`. Defaults to 4.
    attr_reader :main_thread_pool_size

    # Maximum workers in a pool created on another Ractor. Workers start lazily.
    # Can also be set via `FARCE_ADDITIONAL_THREAD_POOL_SIZE`. Defaults to 2.
    attr_reader :additional_thread_pool_size

    # Minimum workers retained by {Farce.in_parallel} on CRuby. Defaults to 0.
    # Configure before the first scheduler is created. Ignored on JRuby and TruffleRuby.
    # @return [Integer]
    attr_reader :parallel_pool_min_size

    # Maximum workers used by {Farce.in_parallel} on CRuby.
    # Defaults to nil, which uses {System.cpu_count} when the pool is created.
    # @return [Integer, nil]
    attr_reader :parallel_pool_max_size

    # Soft task limit for each worker in {Farce.in_parallel}'s CRuby pool.
    # Defaults to 64. Set to nil to disable the limit.
    # @return [Integer, nil]
    attr_reader :parallel_pool_max_inflight

    # Queue wait in seconds before {Farce.in_parallel}'s CRuby pool adds a worker.
    # Defaults to 0.005.
    # @return [Float]
    attr_reader :parallel_pool_grow_after

    # Idle time in seconds before an extra worker in {Farce.in_parallel}'s CRuby pool retires.
    # Defaults to 30. Set to nil to disable idle retirement.
    # @return [Float, nil]
    attr_reader :parallel_pool_shrink_after

    # Pending-task capacity of {Farce.in_parallel}'s CRuby pool.
    # Defaults to 1024. Set to nil for an unbounded queue.
    # @return [Integer, nil]
    attr_reader :parallel_pool_capacity

    PARALLEL_POOL_DEFAULTS = { max_size: nil, min_size: 0, max_inflight: 64,
                               grow_after: 0.005, shrink_after: 30, capacity: 1024 }.freeze
    private_constant :PARALLEL_POOL_DEFAULTS

    # @yield [config] block to modify the configuration
    # @yieldparam config [Config] the configuration object to configure
    def initialize
      yield self if block_given?
      self.autoload_integrations = ENV.fetch("FARCE_AUTOLOAD_INTEGRATIONS", true) if autoload_integrations.nil?
      self.fiber_scheduler       = ENV["FARCE_FIBER_SCHEDULER"] unless instance_variable_defined?(:@fiber_scheduler)
      self.main_thread_pool_size       ||= ENV.fetch("FARCE_MAIN_THREAD_POOL_SIZE", 4)
      self.additional_thread_pool_size ||= ENV.fetch("FARCE_ADDITIONAL_THREAD_POOL_SIZE", 2)
      initialize_parallel_pool
    end

    # @api private
    def marshal_dump
      [1, autoload_integrations, fiber_scheduler, main_thread_pool_size, additional_thread_pool_size,
       parallel_pool_options, frozen?]
    end

    # @api private
    def marshal_load(data)
      if data.is_a?(Array) && data.length == 6
        autoload, scheduler, main_size, additional_size, frozen = Internal::MarshalSupport.payload(data, 5)
        options = {}
      else
        autoload, scheduler, main_size, additional_size, options, frozen = Internal::MarshalSupport.payload(data, 6)
      end

      self.autoload_integrations        = autoload
      self.fiber_scheduler              = scheduler
      self.main_thread_pool_size        = main_size
      self.additional_thread_pool_size  = additional_size
      initialize_parallel_pool(options)
      freeze if frozen
    end

    # Enable or disable automatic integration loading. Already loaded integrations remain active.
    # Enabling this option installs require hooks if they are not already installed.
    # @param value [Boolean, String] true, false, or their environment variable representations.
    # @raise [ArgumentError] If the value is not a supported boolean.
    def autoload_integrations=(value)
      @autoload_integrations = case value
                               when true, "true",   "1" then true
                               when false, "false", "0" then false
                               else raise ArgumentError, "autoload_integrations must be a boolean"
                               end
      if @autoload_integrations && Farce.const_defined?(:Integrations, false) &&
          !Farce.autoload?(:Integrations) && Farce.config.equal?(self)
        Integrations.install_require_hooks
      end
      @autoload_integrations
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

    # Sets a non-negative minimum worker count for the shared parallel pool.
    # It must not exceed an explicitly configured maximum.
    def parallel_pool_min_size=(value)
      value = normalize_parallel_pool_size(value, :min_size, minimum: 0)
      if parallel_pool_max_size && value > parallel_pool_max_size
        raise ArgumentError, "parallel pool min_size must not exceed max_size"
      end
      @parallel_pool_min_size = value
    end

    # Sets a positive maximum worker count, or nil to use the CPU count.
    def parallel_pool_max_size=(value)
      value = normalize_parallel_pool_size(value, :max_size, nil_allowed: true)
      if value && parallel_pool_min_size && value < parallel_pool_min_size
        raise ArgumentError, "parallel pool min_size must not exceed max_size"
      end
      @parallel_pool_max_size = value
    end

    # Sets a positive soft task limit per worker, or nil to disable it.
    def parallel_pool_max_inflight=(value)
      @parallel_pool_max_inflight = normalize_parallel_pool_size(value, :max_inflight, nil_allowed: true)
    end

    # Sets a finite, non-negative queue wait before growing the pool.
    def parallel_pool_grow_after=(value)
      @parallel_pool_grow_after = normalize_parallel_pool_duration(value, :grow_after)
    end

    # Sets a finite, non-negative idle timeout, or nil to disable retirement.
    def parallel_pool_shrink_after=(value)
      @parallel_pool_shrink_after = normalize_parallel_pool_duration(value, :shrink_after, nil_allowed: true)
    end

    # Sets a positive pending-task capacity, or nil for an unbounded queue.
    def parallel_pool_capacity=(value)
      @parallel_pool_capacity = normalize_parallel_pool_size(value, :capacity, nil_allowed: true)
    end

    # Called internally once the configuration is applied.
    def freeze
      return self if frozen?
      super # need to call this first to avoid infinite recursion in the next line
      ::Ractor.make_shareable(self) if defined?(::Ractor.make_shareable)
      self
    end

    private

    def initialize_parallel_pool(options = {})
      PARALLEL_POOL_DEFAULTS.each do |name, default|
        next if instance_variable_defined?(:"@parallel_pool_#{name}")
        public_send(:"parallel_pool_#{name}=", options.fetch(name, default))
      end
    end

    def parallel_pool_options
      PARALLEL_POOL_DEFAULTS.to_h { |name, _| [name, public_send(:"parallel_pool_#{name}")] }
    end

    def normalize_parallel_pool_size(value, name, minimum: 1, nil_allowed: false)
      return if value.nil? && nil_allowed
      value = Integer(value, 10) if value.is_a?(String)
      unless value.is_a?(Integer) && value >= minimum
        raise ArgumentError, "parallel pool #{name} must be an integer >= #{minimum}"
      end
      value
    end

    def normalize_parallel_pool_duration(value, name, nil_allowed: false)
      return if value.nil? && nil_allowed
      value = Float(value)
      raise ArgumentError unless value.finite? && value >= 0
      value
    rescue ArgumentError, TypeError
      raise ArgumentError, "parallel pool #{name} must be finite and non-negative"
    end

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

  # Configures Farce.
  # @example
  #   Farce.configure do |config|
  #     config.fiber_scheduler = :carbon_fiber
  #   end
  # @yield [config] the configuration object
  def self.configure = yield CONFIG

  # @overload config
  #   @return [Config] the global Farce configuration
  def self.config(&)
    configure(&) if block_given?
    CONFIG
  end
end
