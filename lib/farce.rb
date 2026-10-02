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

  UNDEFINED = Internal::Undefined.new("UNDEFINED")

  autoload :DEDUPER, "farce/deduper"
  private_constant :Internal, :UNDEFINED, :DEDUPER

  # @overload transaction(*objects, retries: 100, backoff_after: 10)
  #   Creates and runs a new transaction attempt.
  #   Automatically retries failed attempts up to the specified number of retries.
  #   Starts backing off after the specified number of attempts.
  #
  #   @example Modifying multiple entries in a map
  #     accounts = Farce::Map.new({a: 100, b: 200})
  #
  #     # transfer 80 from :a to :b, but only if both succeed
  #     success = Farce.transaction(accounts) do |tx, accounts|
  #       tx.abort! if accounts[:b] < 80
  #       accounts[:a] += 80
  #       accounts[:b] -= 80
  #     end
  #
  #     if success
  #       puts "Transaction succeeded"
  #     else
  #       puts "Transaction failed"
  #     end
  #
  #   @example Programmatically registering objects for transactions
  #     map     = Farce::Map.new({a: 1, b: 2})
  #     summary = Farce::Atom.new("size not calculated")
  #
  #     # make sure map[:size], map.size, and the summary all match
  #     Farce.transaction do |tx|
  #       tx_map            = tx[map]
  #       tx_map[:size]     = size = tx_map.size
  #       tx[summary].value = "size: #{size}"
  #     end
  #
  #   @param objects [Array] list of objects to enroll in the transaction
  #   @param retries [Integer] maximum additional attempts
  #   @param backoff_after [Integer] number of attempts before starting to back off
  #   @yield [transaction, *objects] the current transaction and the enrolled objects
  #   @yieldparam transaction [Farce::Transaction] the current transaction
  #   @yieldparam objects [Array] the enrolled objects
  #   @return [Boolean] whether the transaction committed successfully
  def self.transaction(...) = Transaction.run(...)

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

  # Deduplicate values using the default {Deduper}.
  # Cached values are held weakly, so retaining only an object_id does not keep
  # its canonical object alive. Keep the returned object to preserve its identity.
  #
  # @overload dedup(object, copy: false, skip: nil)
  #   Reuse equal strings and frozen containers throughout an object graph.
  #   @example Preserve the input
  #     first = Farce.dedup(["foo"], copy: true)
  #     Farce.dedup(["foo"]).equal?(first) # => true
  #   @param object [Object] the root object
  #   @param copy [Boolean, Symbol] false to update the input, true to copy it,
  #     or a copy method such as :clone
  #   @param skip [Module, Array<Module>, nil] additional classes or modules to skip
  #   @return [Object] the deduplicated result
  #
  # @overload dedup
  #   Return the default deduper to configure subsequent calls.
  #   @example Exclude a class and its children
  #     Farce.dedup.skip(SomeClass)
  #   @example Cache another value class
  #     Farce.dedup.store(MyValue)
  #   @return [Deduper]
  # @see Deduper#dedup
  def self.dedup(object = UNDEFINED, **)
    return DEDUPER if UNDEFINED.equal?(object)
    DEDUPER.dedup(object, **)
  end

  # Recursively freeze an object graph using {Walker} traversal.
  #
  # Visits container elements, hash keys and values, and instance variables.
  # Shared children and cycles are preserved.
  #
  # Classes and modules are skipped by default. If it is enabled, then traversal visits
  # instance variables, directly defined public constants, and directly defined class variables.
  # Autoloads are skipped.
  #
  # Freezes objects in place and returns the original root. Already frozen
  # objects are still traversed so their mutable children are frozen too.
  #
  # @example Freeze nested values in place
  #   values = { tags: [+"ruby"] }
  #   Farce.freeze_graph(values).equal?(values)        # => true
  #   values[:tags].frozen?                           # => true
  #   values[:tags].first.frozen?                     # => true
  #
  # @example Freeze children of an already frozen container
  #   values = [+"ruby"].freeze
  #   Farce.freeze_graph(values).equal?(values)        # => true
  #   values.first.frozen?                            # => true
  #
  # @example Freeze module state while allowing new methods
  #   mod = Module.new
  #   mod.instance_variable_set(:@tags, [+"ruby"])
  #   Farce.freeze_graph(mod, traverse_modules: true)
  #   mod.instance_variable_get(:@tags).first.frozen? # => true
  #   mod.frozen?                                     # => false
  #
  # @param object [Object] the root object
  # @param freeze_modules [Boolean] whether to freeze classes and modules
  # @param traverse_modules [Boolean] whether to visit class and module instance
  #   variables. Defaults to `freeze_modules`, but can be set independently.
  # @return [Object] the original root. Skipped modules retain their frozen state.
  # @see Walker
  def self.freeze_graph(object, freeze_modules: false, traverse_modules: freeze_modules)
    Walker.visit(object) do |node, walker|
      if Module === node
        traverse = traverse_modules
        freeze   = freeze_modules
      else
        traverse = true
        freeze   = true
      end

      walker.traverse if traverse
      node.freeze if freeze
      node
    end
  end

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

  # Allows executing code on the main ractor from other ractors.
  # This allows modifying objects and calling methods only accessible from the main ractor.
  #
  # If a block is given, executes it on the main ractor, passing any given arguments to it.
  # Blocks the current thread until the block has finished executing.
  #
  # Arguments are transferred based on the given mode.
  #
  # @!macro modes
  #
  # Calls from the main ractor execute directly, preserving the block and arguments.
  #
  # If no block is given, it returns a scheduler to execute tasks on the main ractor.
  # This allows scheduling without blocking the current thread.
  #
  # On JRuby and TruffleRuby, blocks run inline because there is no native Ractor isolation.
  # The returned {ThreadScheduler} starts a new thread for each scheduled task.
  #
  # @example
  #   $results = []
  #
  #   Farce::Ractor.new do
  #     # maybe computing this string on the main ractor is too expensive?
  #     my_string = "foo bar baz"
  #
  #     # can't access $results on the current ractor directly, as it isn't shareable
  #     Farce.on_main(my_string) { $results << it }
  #   end.join
  #
  #   $results # => ["foo bar baz"]
  #
  # @example Blocking vs non-blocking
  #   Farce::Ractor.new do
  #     # This blocks the current thread until the block has finished executing.
  #     Farce.on_main do
  #       sleep 1
  #       puts "Hi from the main ractor!"
  #     end
  #
  #     # This does not block the current thread.
  #     Farce.on_main.schedule do
  #       sleep 1
  #       puts "Hi again from the main ractor!"
  #     end
  #
  #     puts "Hi from the current ractor!"
  #   end
  #
  #   sleep 3 # Wait for all scheduled tasks to complete.
  #
  #   # Expected output:
  #   # Hi from the main ractor!
  #   # Hi from the current ractor!
  #   # Hi again from the main ractor!
  #
  # @overload on_main(*args, mode: :copy)
  #   @param args [Array] The arguments to be passed to the block.
  #   @param mode [Symbol] The argument transfer mode when called from another ractor.
  #   @yield [*args] The block to be executed on the main ractor.
  #   @yieldparam [*args] The arguments passed to the block.
  #   @return [nil]
  #
  # @overload on_main
  #   Returns a scheduler that executes tasks on the main ractor.
  #   @return [Abstract::Scheduler]
  #
  # @return [Abstract::Scheduler, nil]
  # @see .in_parallel
  def self.on_main(*args, mode: UNDEFINED, &)
    unless block_given?
      raise LocalJumpError, "no block given" unless args.empty? && UNDEFINED.equal?(mode)
      return Internal::MainScheduler
    end

    if Ractor.main?
      yield(*args)
    else
      mode = :copy if UNDEFINED.equal?(mode)
      Internal::MainScheduler.execute(*args, mode:, auto_local: false, &)
    end

    nil
  end

  # Schedules work without waiting for the block to finish.
  # On CRuby, uses a shared Ractor pool with at most {System.cpu_count} workers.
  # On JRuby and TruffleRuby, starts a new thread for each task.
  #
  # Without a block, returns the shared scheduler. The CRuby pool starts workers
  # when tasks arrive. Pass mutable task data as arguments so it can be transferred based on the given mode.
  #
  # @!macro modes
  #
  # @example
  #   Farce.in_parallel("hello") { |message| puts message.upcase }
  #   Farce.in_parallel.schedule { puts "another task" }
  #
  # @overload in_parallel(*args, mode: :copy)
  #   @param args [Array<Object>] Arguments passed to the block.
  #   @param mode [Symbol] Argument transfer mode. Ignored on JRuby and TruffleRuby.
  #   @yield [*args] The task to schedule.
  #   @return [nil]
  #
  # @overload in_parallel
  #   @return [Abstract::Scheduler] The shared scheduler.
  #
  # @return [Abstract::Scheduler, nil]
  # @see .on_main
  def self.in_parallel(*args, mode: UNDEFINED, &)
    unless block_given?
      raise LocalJumpError, "no block given" unless args.empty? && UNDEFINED.equal?(mode)
      return Internal::ParallelScheduler
    end

    mode = :copy if UNDEFINED.equal?(mode)
    Internal::ParallelScheduler.schedule(*args, mode:, &)
    nil
  end

  # @overload schedule(*args, mode: :copy, auto_local: true, **kwargs)
  #   Schedules work to be executed out of band.
  #
  #   If the `mode` is set to `:local`, it will use the current thread's fiber scheduler to schedule the task.
  #   If no fiber scheduler is available, it will create or reuse a Ractor-local scheduler (on the main Ractor,
  #   this is the same scheduler as {.on_main} uses).
  #
  #   If `auto_local` is set to `true` (but with a different `mode`), the same logic is used as in local mode, except
  #   it will not create a new ractor-local scheduler if one is not already available.
  #
  #   @example Scheduling work
  #     # just run this asynchronously, don't care how
  #     Farce.schedule("hello") { |message| puts message.upcase }
  #
  #   @example Using a fiber scheduler
  #     Async do
  #       # this is basically the same as calling Async { do_something }
  #       Farce.schedule { do_something }
  #     end
  #
  #   @param args [Array<Object>] Arguments passed to the block.
  #   @param mode [Symbol] Argument transfer mode. Ignored on JRuby and TruffleRuby.
  #   @param auto_local [Boolean] Whether to automatically use the local scheduler if available.
  #   @param kwargs [Hash] Additional keyword arguments passed to the scheduler.
  #   @yield [*args] The task to schedule.
  #   @return [nil]
  def self.schedule(*, mode: :copy, auto_local: true, **, &)
    raise LocalJumpError, "no block given" unless block_given?

    if auto_local || mode == :local
      if Fiber.respond_to?(:scheduler) && fiber_scheduler = Fiber.scheduler
        fiber_scheduler.fiber(**) { yield(*) }
        return
      end
      scheduler = Ractor.main? ? Internal::MainScheduler : Internal::Storage[:local_scheduler]
    end

    scheduler ||=
      if mode == :local
        Internal::Storage.store_if_absent(:local_scheduler) do
          Internal.native_ractors? ? Scheduler.create(Thread) : ThreadScheduler.new
        end
      else
        Internal::ParallelScheduler
      end

    scheduler.schedule(*, mode:, auto_local:, **, &)
    nil
  end

  def self.append_features(mod) = Internal::Mixin.__send__(:append_features, mod)
  def self.included(mod)        = Internal::Mixin.__send__(:included, mod)
  private_class_method :append_features, :included

  Integrations.setup
  Internal.finalize_engine
end
