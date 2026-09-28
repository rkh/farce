# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # A proxy mimics the API of another object, executing method calls within the Ractor that created it.
  # This is an easy way to have drop-in replacements for objects that cannot be shared across Ractors.
  # Delegated calls raise Ractor::RemoteError after the owner exits.
  #
  # ```ruby
  # # Mutable arrays aren't Ractor-shareable
  # array   = []
  # proxied = []
  # proxy   = Farce::Proxy.new(proxied)
  #
  # Farce::Ractor.new(array, proxy) do |*list|
  #   list.each { it << 42 }
  # end.join
  #
  # # The array got copied instead of being modified in place
  # array # => []
  #
  # # The proxy didn't get copied
  # proxied # => [42]
  # ```
  #
  # ## Customizing Proxy Behavior
  #
  # Imagine we have an unshareable class:
  #
  # ```ruby
  # class MyClass
  #   include Farce::Unshareable
  #   attr_reader :record
  #
  #   def initialize = @record = []
  #   def <<(value) = @record << value
  # end
  # ```
  #
  # We can use a proxy to still allow cross-ractor access:
  #
  # ```ruby
  # my_instance = MyClass.new
  # my_proxy    = Farce::Proxy.create(my_instance)
  #
  # Ractor.new(my_proxy) { it << 42 }.join
  #
  # my_instance.record # => [42]
  # ```
  #
  # The above example has one issue:
  # We cannot chain the calls, because `<<` returns an array, which actually gets copied.
  #
  # ```ruby
  # my_instance = MyClass.new
  # my_proxy    = Farce::Proxy.create(my_instance)
  #
  # Ractor.new(my_proxy) { it << 42 << 43 }.join
  #
  # my_instance.record # => [42]
  # ```
  #
  # We could easily fix this inside `MyClass` by returning `self` from `<<`, but maybe we don't actually control
  # `MyClass`? In that case, we can add a proxy definition:
  #
  # ```ruby
  # # The "inner" layer runs in the same ractor that the proxied object lives in.
  # Farce::Proxy.define(MyClass, layer: :inner) do
  #   # Also proxy the value returned by `<<`
  #   def <<(...) = __proxy__(super)
  # end
  #
  # my_instance = MyClass.new
  # my_proxy    = Farce::Proxy.create(my_instance)
  #
  # Ractor.new(my_proxy) { it << 42 << 43 }.join
  #
  # my_instance.record # => [42, 43]
  # ```
  #
  # ### Advanced customization
  #
  # The proxy wrappers define methods for all supported {file:docs/modes.md modes}. Use the outer wrapper for argument
  # handling and memoization, use the inner wrapper for handling return values:
  #
  # ```ruby
  # # This class cannot easily be shared across Ractors, as it uses a Mutex and a mutable array.
  # class MyClass
  #   attr_reader :capacity
  #
  #   def initialize(capacity = 100)
  #     @capacity = Integer(capacity)
  #     @record   = []
  #     @mutex    = Mutex.new
  #   end
  #
  #   def add(value)
  #     @mutex.synchronize do
  #       return false if @record.size >= @capacity
  #       @record << value
  #       true
  #     end
  #   end
  #
  #   def to_a = @record.dup
  # end
  #
  # # Lets define some rules
  #
  # Farce::Proxy.define(MyClass, layer: :outer) do
  #   # Capacity doesn't change, so we can memoize it.
  #   def capacity = @capacity ||= super
  #
  #   # Maybe a common use-case is adding MyClass instances to MyClass instances?
  #   # If so, maybe we want to proxy these as well? Make everything else shareable.
  #   def add(value)
  #     value = __proxy__(value) if value.is_a? MyClass
  #     super __make_shareable__(value)
  #   end
  # end
  #
  # Farce::Proxy.define(MyClass, layer: :inner) do
  #   # to_a already creates a new array every time, we don't have to copy it again
  #   def to_a = __move__(super)
  # end
  # ```
  #
  # Proxies should mimic the original object's interface as closely as possible, but nothing keeps you from adding
  # custom methods:
  #
  # ```ruby
  # class MyClass
  #   def is_proxy? = false
  # end
  #
  # Farce::Proxy.define(MyClass) do
  #   def is_proxy? = true
  #   def proxy_method = "Hi from the proxy!!!"
  # end
  #
  # my_instance = MyClass.new
  # my_proxy    = Farce::Proxy.create(my_instance)
  #
  # my_instance.is_proxy? # => false
  # my_proxy.is_proxy?    # => true
  #
  # my_proxy.proxy_method if my_proxy.is_proxy? # => "Hi from the proxy!!!"
  # ```
  class Proxy < BasicObject
    include ::Farce.const_get(:Internal)::Autoloads
    include ::Farce.const_get(:Internal)::Delegation

    REGISTER   = Register.new
    SELF       = ::Object.new.freeze
    UNDEFINED  = ::Farce.const_get(:UNDEFINED)
    ProxyOwner = ::Farce.const_get(:Internal)::ProxyOwner

    private_constant :Supervisor, :Wrapper, :REGISTER, :SELF, :UNDEFINED, :ProxyOwner

    define_method(:respond_to?, ::Kernel.instance_method(:respond_to?))
    define_method(:__freeze__,  ::Kernel.instance_method(:freeze))
    private :__freeze__

    # @return [Farce::Proxy::Register] the default register used by the proxy class
    def self.default_register = REGISTER

    # @overload define(klass, layer: :outer)
    #   (see Farce::Proxy::Register#define)
    #   @see .default_register
    #   @see Farce::Proxy::Register#define
    def self.define(...) = REGISTER.define(...)

    # @overload create(object, register: nil, scheduler: nil)
    #   Creates a new proxy for the given object if it is not Ractor-shareable.
    #   Returns the given object otherwise.
    #   @param (see Farce::Proxy#initialize)
    #
    # @overload create(register: nil)
    #   Creates a new Ractor, runs the given block within it, and returns the result.
    #   If the result is not Ractor-shareable, it will be proxied.
    #   The new Ractor stops after its proxies are collected.
    #
    #   @yield The block to be executed within the new Ractor.
    #   @yieldreceiver [nil]
    #
    # @overload create(scheduler:, register: nil)
    #   Schedules the given block to be executed by the specified scheduler.
    #   Returns its result. If the result is not Ractor-shareable, it will be proxied.
    #
    #   @yield The block to be executed by the scheduler.
    #   @yieldreceiver [nil]
    #
    # @return [BasicObject, Farce::Proxy] the proxied object or the original object if it is Ractor-shareable
    def self.create(object = UNDEFINED, register: nil, scheduler: nil, &)
      if UNDEFINED.equal?(object)
        initializer = ::Farce::Strict::Atom.new(::Farce::Ractor.shareable_proc(&))
        success     = ::Farce::Strict::Atom.new
        result      = ::Farce::Strict::Atom.new
        owned       = scheduler.nil?
        scheduler ||= owner_scheduler

        schedule_initializer(scheduler, initializer, register, success, result, owned)

        success.wait_until_non_nil
        return result.swap(nil) if success.value
        raise ::Farce::Ractor::RemoteError, result.swap(nil)
      end

      return object if Ractor.shareable?(object)
      new(object, register:, scheduler:)
    end

    def self.owner_scheduler = ::Farce::ThreadScheduler.new { |*args, &block| ::Farce::Ractor.new(*args, &block) }
    private_class_method :owner_scheduler

    def self.schedule_initializer(scheduler, *)
      scheduler.schedule(*) do |initializer, register, success, result, owned|
        local_scheduler = ::Farce::Proxy.__send__(:initialize_proxy, initializer, register, success, result, owned)
        result = nil
        ProxyOwner.drain_scheduler(local_scheduler) if local_scheduler
      rescue ::StandardError => e
        raise unless result
        result.value  = -"#{e.class}: #{e.message}"
        success.value = false
      ensure
        local_scheduler&.close
      end
    end
    private_class_method :schedule_initializer

    # Keep initializer and proxy temporaries out of the frame that drains the owner.
    def self.initialize_proxy(initializer, register, success, result, owned)
      initialized = initializer.swap(nil).call
      local_scheduler = nil
      local_scheduler = ProxyOwner.create_scheduler if owned && !::Farce::Ractor.shareable?(initialized)
      result.value = ::Farce::Proxy.create(initialized, register:, scheduler: local_scheduler)
      success.value = true
      local_scheduler
    rescue ::Exception # rubocop:disable Lint/RescueException -- Close the owned scheduler before propagating initialization failures.
      local_scheduler&.close
      raise
    end
    private_class_method :initialize_proxy

    # @param object [BasicObject] the object to be managed by the proxy
    # @param register [Farce::Proxy::Register, nil] the register to use
    # @param scheduler [Farce::Abstract::Scheduler, nil] the scheduler to use
    def initialize(object, register: nil, scheduler: nil)
      @token        = ::Object.new.freeze # cross-ractor finalizers don't work reliably across Ruby versions
      @supervisor   = Supervisor.new(register || REGISTER, scheduler || ::Farce, ::Farce::WeakValue.new(@token))
      @proxy_class  = ::Kernel.instance_method(:class).bind_call(self)
      @object_class = ::Kernel.instance_method(:class).bind_call(object)
      @object_id    = ::BasicObject.instance_method(:__id__).bind_call(object)
      __freeze__
      @supervisor.run(object)
    end

    # @return [true] proxies can be shared even when their targets cannot
    def ractor_shareable? = true

    # @note Does not call `#inspect` on the proxied object itself, to avoid Ractor round-trips
    # @return [String] a string representation of the proxy object
    def inspect = "#<#{@proxy_class.inspect} object=#<#{@object_class.inspect}:0x#{@object_id.to_s(16)}>>"

    # @api private
    def pretty_print(pp)
      pp.group(1, "#<#{@proxy_class.inspect} ", ">") do
        pp.text "object="
        pp.text "#<#{@object_class.inspect}:0x#{@object_id.to_s(16)}>"
      end
    end

    private

    # Dispatches method calls to be processed by the Ractor the proxied object resides in.
    def method_missing(...)
      result = @supervisor.send(...)
      SELF.equal?(result) ? self : result
    end

    def respond_to_missing?(...) = @supervisor.method_defined?(...)
  end
end
