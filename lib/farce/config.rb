# frozen_string_literal: true
# warn_indent: true

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
  #   c.fiber_scheduler_implementation = :select
  # end
  # ```
  class Config
    # The fiber scheduler implementation to use for Farce's built-in fiber scheduler.
    # This primarily impacts which scheduler implementation is loaded.
    #
    # Can also be set via the `FARCE_FIBER_SCHEDULER_IMPLEMENTATION` environment variable.
    #
    # @return [Symbol] the fiber scheduler implementation to use. One of `:native`, `:select`, or `:jvm`.
    attr_reader :fiber_scheduler_implementation

    # Default IO driver for new schedulers. An explicit `backend:` overrides this value.
    # Availability is checked by the selected implementation when a scheduler is created.
    # Can also be set via `FARCE_IO_BACKEND`.
    # @return [Symbol] one of `:auto`, `:epoll`, `:kqueue`, `:io_uring`, `:select`, or `:nio`
    attr_reader :io_backend

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
      self.fiber_scheduler_implementation ||= ENV["FARCE_FIBER_SCHEDULER_IMPLEMENTATION"]
      self.io_backend                     ||= ENV["FARCE_IO_BACKEND"]
      self.main_thread_pool_size          ||= ENV.fetch("FARCE_MAIN_THREAD_POOL_SIZE", 4)
      self.additional_thread_pool_size    ||= ENV.fetch("FARCE_ADDITIONAL_THREAD_POOL_SIZE", 2)
    end

    # Sets the fiber scheduler implementation to use. One of `:detect`, `:native`, `:select`, or `:jvm`.
    # @param value [Symbol, String, nil] the fiber scheduler implementation to use
    # @raise [ArgumentError] if the value is not one of `:native`, `:select`, or `:jvm`
    def fiber_scheduler_implementation=(value)
      @fiber_scheduler_implementation = normalize_fiber_scheduler_implementation(value)
    end

    # Sets the default IO driver. Nil, empty strings and `:detect` select `:auto`.
    # @param value [Symbol, String, nil] the IO driver to use
    # @raise [ArgumentError] if the driver name is unknown
    def io_backend=(value)
      @io_backend = normalize_io_backend(value)
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

    def normalize_io_backend(value)
      case value
      when nil, "", :detect, "detect"                             then :auto
      when :auto, :epoll, :kqueue, :io_uring, :select, :nio       then value
      when "auto", "epoll", "kqueue", "io_uring", "select", "nio" then value.to_sym
      else raise ArgumentError, "unknown IO backend: #{value.inspect}"
      end
    end

    def normalize_fiber_scheduler_implementation(value)
      case value
      when nil, "", :detect, "detect"
        case RUBY_ENGINE
        when "ruby"  then RUBY_PLATFORM.match?(/linux|darwin|bsd/) ? :native : :select
        when "jruby" then :jvm
        else :select
        end
      when :native,  :select,  :jvm  then value
      when "native", "select", "jvm" then value.to_sym
      else raise ArgumentError, "unknown fiber scheduler implementation: #{value.inspect}"
      end
    end
  end

  CONFIG = Config.new
  private_constant :CONFIG

  def self.config
    yield CONFIG if block_given?
    CONFIG
  end
end
