# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

begin
  # We don't actually use Zeitwerk, but this works around a Zeitwerk bug.
  # Zeitwerk might break if a Ractor starts before it is loaded.
  #
  #   Ractor.new {}
  #   require "zeitwerk"
  #   require "zeitwerk" # NoMethodError: super: no superclass method 'require' for main
  #
  # This has absolutely nothing to do with Farce, except that Farce might create a Ractor.
  require "zeitwerk"
rescue LoadError => e
  raise unless e.path == "zeitwerk"
end

require "farce/config"
require "farce/internal"
require "farce/engine/#{RUBY_ENGINE}"
require "farce/version"
require "farce/error"
require "farce/system"

# Namespace for everything provided by Farce.
#
# ## Including Farce
#
# Including Farce in a class or module will include **all public camel-case constants** defined under the Farce
# namespace.
#
# ```ruby
# require "farce"
#
# # This could also be done under a class or module, to avoid polluting the global namespace.
# include Farce
#
# # Now Ractor is available, even on JRuby or TruffleRuby!
# Ractor.new { puts "Hello from a Ractor!" }
#
# # Other constants are also available.
# Clock.parse(1.minute.from_now)
#
# # VERSION is not exposed. This is to avoid polluting other libraries with it.
# defined?(VERSION) # => false
# ```
module Farce
  include Internal::Autoloads

  MAYBE     = Internal::ConstMissing.new(Object, ignore: %i[NativeException RubyLex])
  UNDEFINED = Internal::Undefined.new("UNDEFINED")
  private_constant :Internal, :MAYBE, :UNDEFINED

  # @overload clock
  #   The current clock time
  #
  # @overload clock(value)
  #   Parses value into a monotonic clock time.
  #   @param value [nil, Numeric, Time, ActiveSupport::Duration, Hash] the value to convert to clock time
  #   @see Clock.parse
  #
  # @overload clock(at:)
  #   Gives the clock time for a fixed point in time. Independent of the current time.
  #   @param at [Numeric, Time] the value to convert to clock time
  #
  # @overload clock(time:)
  #   Gives the clock time for a fixed point in time. Independent of the current time.
  #   @param time [Numeric, Time] the value to convert to clock time
  #
  # @overload clock(timeout_at:)
  #   Gives the clock time for a fixed point in time. Independent of the current time.
  #   @param timeout_at [Numeric, Time] the value to convert to clock time
  #
  # @overload clock(delay:)
  #   Gives the clock time for a relative offset from the current time.
  #   @param delay [Numeric] the value to convert to clock time
  #
  # @overload clock(offset:)
  #   Gives the clock time for a relative offset from the current time.
  #   @param offset [Numeric] the value to convert to clock time
  #
  # @overload clock(timeout:)
  #   Gives the clock time for a relative offset from the current time.
  #   @param timeout [Numeric] the value to convert to clock time
  #
  # @overload clock(wait:)
  #   Gives the clock time for a relative offset from the current time.
  #   @param wait [Numeric] the value to convert to clock time
  #
  # @return [Float] monotonic clock time in seconds, from when clock was called the first time
  def self.clock(...) = Clock.parse(...)

  # Binds a proc, lambda, block, bound or unbound method to a new self.
  #
  # This is similar to the following common approaches:
  #
  # 1. **`Ractor`**: using `Ractor.shareable_proc`/`Ractor.shareable_lambda`
  # 2. **`BasicObject`**:  using `#instance_exec`/`#instance_eval` (used by many DSLs, like Hanami or the dry-rb gems)
  # 3. **`Module`**: using `#define_method` and method binding (used by many DSLs, like Sinatra or the money gem)
  #
  # Approach 2 and 3 are very popular for DSLs, but the resulting objects cannot be shared across ractors.
  # The first approach fixes that, but only works on a limited number of procs and receivers, and is not available on
  # all Ruby implementations.
  #
  #  Property                           | `Ractor`   | `BasicObject` | `Module`      | `Farce`
  # ------------------------------------|------------|---------------|---------------|----------
  #  Works with every proc              | 🚫 **no**   | ✅ yes        | ✅ yes        | ✅ yes
  #  Results can be made shareable      | ✅ yes      | 🚫 **no**     | 🚫 **no**     | ✅ yes
  #  Preserves parameters               | ✅ yes      | 🚫 **no**     | ✅ yes        | ✅ yes
  #  Procs can accept blocks            | ✅ yes      | 🚫 **no**     | ✅ yes        | ✅ yes
  #  Preserves lambda-ness              | ⚠️ manually | 🚫 **no**     | 🚫 **no**     | ✅ yes
  #  Works on JRuby and TruffleRuby     | 🚫 **no**   | ✅ yes        | ✅ yes        | ✅ yes
  #  Performance overhead               | ✅ none     | ⚠️ up to 200% | ⚠️ up to 80%  | ✅ none
  #
  # If you want the proc to also be shareable, use {Ractor.shareable_proc} instead.
  #
  # The performance overhead of `BasicObject#instance_exec`/`BasicObject#instance_eval` is the most significant on the
  # official Ruby implementation, but is still present on JRuby, which does not exhibit a performance penalty for
  # `Module#define_method`. On TruffleRuby, all approaches have similar performance. The more work is done inside
  # the proc, the less significant the overhead becomes.
  #
  # @example
  #   # Rebinding a block to a new self
  #   callback = Farce.rebind(self: 42) { self * 10 }
  #   callback.call # => 420
  #
  #   # Rebound procs preserve parameters and can accept blocks
  #   block   = ->(key, &fallback) { fetch(key, &fallback) }
  #   rebound = Farce.rebind(block, self: { a: 1, b: 2 })
  #   rebound.call(:a) { 0 } # => 1
  #   rebound.call(:c) { 0 } # => 0
  #   rebound.parameters == block.parameters # => true
  #
  #   # Rebinding an unbound method to a new self returns a bound method
  #   method = Object.instance_method(:inspect) # => #<UnboundMethod>
  #   method = Farce.rebind(method, self: 42)   # => #<Method>
  #   method.receiver # => 42
  #   method.call     # => "42"
  #
  #   # lambda-ness is preserved
  #   Farce.rebind(proc {}).lambda?   # => false
  #   Farce.rebind(lambda {}).lambda? # => true
  #
  #   # If there is no binding change, identity is preserved
  #   Farce.rebind(&:to_s) == :to_s.to_proc # => true
  #
  # @overload rebind(self: nil, lambda: nil)
  #   @yield The block to bind to the new self.
  #   @yieldreceiver [BasicObject] The object passed as `self` (or `nil`)
  #   @param self [BasicObject] The new self to bind to.
  #   @return [Proc] The bound proc.
  #
  # @overload rebind(bindable, self: nil, lambda: nil)
  #   @param bindable [Proc, Method, UnboundMethod] The proc or method to bind to the new self.
  #   @param self [Object] The new self to bind to.
  #   @return [Proc, Method]
  #     The bound proc or method.
  #     A method is returned if the argument was a Method or UnboundMethod, otherwise a Proc is returned.
  #
  # @!macro rebind_lambda
  #   @param lambda [Boolean, nil]
  #     If true, a block-based proc will be converted to a lambda. If false to a non-lambda proc.
  #     If nil, the original lambda-ness will be preserved.
  #     Ignored for methods or procs not based on blocks (like `Symbol#to_proc`).
  #
  # @return [Proc, Method] The bound proc or method.
  def self.rebind(bindable = nil, lambda: nil, **self_option, &block)
    raise ArgumentError, "more than one block given" if bindable && block
    raise ArgumentError, "tried to create Proc object without a block" unless bindable ||= block
    new_self = Internal.self_option(self_option)

    if bindable.is_a? Proc
      return bindable if !Internal.rebindable?(bindable) || bindable.binding.receiver.equal?(new_self)
      rebound = Internal.rebind(bindable, new_self, lambda)
      rebound.freeze if bindable.frozen?
      return rebound
    end

    if bindable.is_a? Method
      return bindable if bindable.receiver.equal?(new_self)
      bindable = bindable.unbind
    end

    return bindable.bind(new_self) if bindable.is_a? UnboundMethod
    raise ArgumentError, "invalid bindable: #{bindable.inspect}"
  end

  def self.append_features(mod) = Internal::Mixin.__send__(:append_features, mod)
  def self.included(mod)        = Internal::Mixin.__send__(:included, mod)
  private_class_method :append_features, :included

  Integrations.setup
end
