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

    StrictAtom    = Atom
    StrictLFUMap  = ShareableLFUMap
    StrictLRUMap  = ShareableLRUMap
    StrictTreeMap = ShareableTreeMap

    autoload :ParallelScheduler,    "farce/engine/ruby/shared/parallel_scheduler"
    autoload :MainScheduler,        "farce/engine/ruby/shared/main_scheduler"
    autoload :Lease,                "farce/engine/ruby/shared/lease"
    autoload :LeasePool,            "farce/engine/ruby/shared/lease_pool"
    autoload :StrictMap,            "farce/engine/ruby/shared/strict_map"
    autoload :StrictWeakKeyMap,     "farce/engine/ruby/shared/strict_map"
    autoload :StrictWeakMap,        "farce/engine/ruby/shared/strict_map"
    autoload :StrictWeakValueMap,   "farce/engine/ruby/shared/strict_map"
    autoload :WeakAtom,             "farce/engine/ruby/shared/weak_atom"     unless const_defined?(:WeakAtom, false)
    autoload :UnsharedWeakAtom,     "farce/engine/shared/unshared_weak_atom" unless const_defined?(:UnsharedWeakAtom,
      false)
    autoload :UnsharedAtom,         "farce/engine/shared/unshared_atom"
    autoload :UnsharedVector,       "farce/engine/ruby/shared/unshared_vector"
    autoload :UnsharedMap,          "farce/engine/shared/unshared_weak_map"
    autoload :UnsharedWeakMap,      "farce/engine/shared/unshared_weak_map"
    autoload :UnsharedWeakKeyMap,   "farce/engine/shared/unshared_weak_map"
    autoload :UnsharedWeakValueMap, "farce/engine/shared/unshared_weak_map"
    autoload :FiberScheduler,       "farce/engine/ruby/fiber_scheduler"

    autoload :BasePort,       "#{ENGINE_PATH}/port"
    autoload :Port,           "#{ENGINE_PATH}/port"
    autoload :RactorMethods,  "#{ENGINE_PATH}/ractor_methods"
    autoload :Vault,          "#{ENGINE_PATH}/vault"

    def native_ractors? = true

    def prepare_method_definition(&) = Ractor.shareable_proc(&)

    if ::Ractor.const_defined?(:Port, false)
      def native_ports? = true
    else
      def native_ports? = false
    end

    # Native waits opt in through the scheduler's ractor_selector method.
    # Blocking fibers use Ruby directly, including the helper's result retrieval.
    # Version-specific hooks retain native timeout support and method visibility.
    patch = lambda do |namespace, *methods, signature: "...", schedule: "self, ...", before: nil|
      methods.each do |method|
        visibility = namespace.private_method_defined?(method) ? "private" : "public"
        namespace.class_eval <<~RUBY, __FILE__, __LINE__ + 1
          alias #{method}! #{method}
          private :#{method}!

          def #{method}(#{signature})
            #{before}
            scheduler = Fiber.scheduler unless Fiber.blocking?
            selector = scheduler.ractor_selector if scheduler.respond_to?(:ractor_selector)
            return #{method}!(#{signature}) unless selector
            selector.ractor_#{method}(#{schedule})
          end
          #{visibility} :#{method}
        RUBY
      end
    end

    require "#{ENGINE_PATH}/ractor_selector"
    RactorSelector.install_hooks(patch)
    ::Ractor.singleton_class.alias_method :recv, :receive
    ::Ractor.alias_method :recv, :receive
  end
end

require "farce/engine/ruby/key_lock_map"
