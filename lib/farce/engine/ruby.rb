# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# Load the scheduler dependency before native initialization.
# Late Resolv loading can crash RubyGems for some reason
require "resolv"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    # Compiled extensions and Ruby helpers share one directory for each CRuby ABI.
    ENGINE_PATH = "farce/engine/ruby/#{RUBY_VERSION[/^\d+\.\d+/]}".freeze
    private_constant :ENGINE_PATH

    begin
      require "#{ENGINE_PATH}/rebind"
      require "#{ENGINE_PATH}/farce"
    rescue LoadError => e
      # simplecov:disable
      warn <<~WARNING
        Farce: Failed to load native extension for Ruby #{RUBY_VERSION}.
        Please run `rake compile` to build the extension.
      WARNING
      raise e
      # simplecov:enable
    end

    unless const_defined?(:NATIVE_WEAK_MAPS, false) && NATIVE_WEAK_MAPS
      autoload :WeakMap,      "farce/engine/ruby/shared/weak_map"
      autoload :WeakKeyMap,   "farce/engine/ruby/shared/weak_map"
      autoload :WeakValueMap, "farce/engine/ruby/shared/weak_map"
    end

    StrictAtom = Atom

    autoload :WeakAtom,         "farce/engine/ruby/shared/weak_atom"     unless const_defined?(:WeakAtom, false)
    autoload :UnsharedWeakAtom, "farce/engine/shared/unshared_weak_atom" unless const_defined?(:UnsharedWeakAtom, false)

    autoload :UnsharedWeakMap,      "farce/engine/shared/unshared_weak_map"
    autoload :UnsharedWeakKeyMap,   "farce/engine/shared/unshared_weak_map"
    autoload :UnsharedWeakValueMap, "farce/engine/shared/unshared_weak_map"

    autoload :FiberScheduler, "farce/engine/ruby/fiber_scheduler"
    autoload :BasePort,       "#{ENGINE_PATH}/port"
    autoload :Port,           "#{ENGINE_PATH}/port"
    autoload :RactorMethods,  "#{ENGINE_PATH}/ractor_methods"
    autoload :Vault,          "#{ENGINE_PATH}/vault"

    def native_ractors? = true

    # Sets up hooks on Ractor and Ractor::Port to allow Fiber schedulers to intercept calls to
    # Ractor.select, Ractor.receive, Ractor#join, Ractor#receive, Ractor#value, and Ractor::Port#receive.
    patch = lambda do |namespace, *methods, signature: nil, schedule: signature|
      methods.each do |method|
        next unless namespace.method_defined?(method)
        namespace.class_eval <<~RUBY, __FILE__, __LINE__ + 1
          alias #{method}! #{method}
          private :#{method}!

          def #{method}(#{signature})
            return #{method}!(#{signature}) unless selector = Thread.current[:farce_ractor_selector]
            selector.ractor_#{method}(#{schedule || "self"})
          end
        RUBY
      end
    end

    # Patch Ractor
    patch[Ractor.singleton_class, :select, signature: "..."]
    patch[Ractor.singleton_class, :receive, signature: "...", schedule: "Ractor.current"]
    patch[Ractor, :join, :value]
    patch[Ractor, :receive, signature: "..."]
    Ractor.alias_method :recv, :receive

    # Patch the native Ractor::Port. A shim may define this constant on older Ruby.
    patch[Ractor::Port, :receive, signature: "...", schedule: "self"] if RUBY_VERSION >= "4"
  end
end
