# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    version = RUBY_VERSION[/^\d+\.\d+/]
    path    = "farce/engine/ruby/#{version}"

    begin
      require "#{path}/rebind"
    rescue LoadError => e
      # simplecov:disable
      warn <<~WARNING
        Farce: Failed to load native extension for Ruby #{version}.
        Please run `rake compile` to build the extension.
      WARNING
      raise e
      # simplecov:enable
    end

    autoload :Atom,          "farce/engine/ruby/containers"
    autoload :Map,           "farce/engine/ruby/containers"
    autoload :Queue,         "farce/engine/ruby/containers"
    autoload :WeakMap,       "farce/engine/ruby/containers"
    autoload :WeakKeyMap,    "farce/engine/ruby/containers"
    autoload :WeakValueMap,  "farce/engine/ruby/containers"
    autoload :BasePort,      "#{path}/port"
    autoload :Port,          "#{path}/port"
    autoload :RactorMethods, "#{path}/ractor_methods"
    autoload :MultiRBTree,   "#{path}/rbtree"
    autoload :RBTree,        "#{path}/rbtree"
    autoload :TreeMap,       "farce/engine/ruby/shared/tree_map"

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

    # Patch Ractor::Port
    patch[Ractor::Port, :receive, signature: "...", schedule: "self"] if RUBY_VERSION >= "4"
  end
end
