# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Visit an object graph or transform it with copies only where needed.
  #
  # Traversal follows container elements, hash keys and values, and ordinary
  # instance variables. Farce containers expose their contents, not their storage.
  # Proc traversal follows the receiver, not captured local variables.
  # Module and class traversal includes directly defined public constants and
  # class variables. Set constants: :inherited or class_variables: :inherited
  # to include ancestors, or false to skip either kind. Autoloads are not loaded.
  #
  # {.visit} and {.modify} let the callback choose when to descend with {#traverse}.
  # {.each} descends automatically and yields children before their parent.
  # Shared children and cycles are tracked by identity.
  #
  # @example Scan a namespace without changing it
  #   namespace = Module.new
  #   namespace.const_set(:VALUE, [42])
  #   Farce::Walker.any?(namespace) { Integer === it } # => true
  #   Farce::Walker.any?(namespace, constants: false) { Integer === it } # => false
  #
  # @example Replace integers in a copy
  #   Farce::Walker.modify([1, [2]], copy: true) do |object, walker|
  #     Integer === object ? object + 1 : walker.traverse
  #   end # => [2, [3]]
  class Walker
    module SendTo
      private

      def send_to(object, method, ...)
        object.__send__(method, ...)
      rescue NoMethodError => e
        raise e unless e.name == method && e.receiver.equal?(object)
        Kernel.instance_method(method).bind_call(object, ...)
      end
    end

    class Visitor
      include Shareable::Immutable
      include SendTo

      attr_reader :base_class

      def initialize(base_class)
        @base_class = base_class
        super()
      end

      def call(object, walker) = traverse(object, walker)
    end

    include SendTo

    REGISTER = ClassMirror.new(Visitor) { _1.new(_2) }
    SKIP     = Object.new.freeze
    RETURN   = Object.new.freeze

    private_constant :SendTo, :Visitor, :REGISTER, :SKIP, :RETURN
    private_class_method :new

    # Register traversal for classes from the main Ractor.
    #
    # Subclasses inherit the nearest definition. Definitions can call `super`.
    # Use {#update} to visit children and record assignments. Its block receives
    # a writable target and transformed children. Return that target from the
    # assignment block and return the update result from the definition.
    #
    # Should only be necessary for classes using storage defined outside of Ruby (like a C struct).
    #
    # @example
    #   # Lets assume NativeClass has a natively stored value
    #   Farce::Walker.define(NativeClass) do |object, walker|
    #     walker.update(object, [object.value]) do |target, values|
    #       target.value = values.first
    #       target
    #     end
    #   end
    #
    # @param classes [Array<Class>] classes to handle
    # @yieldparam object [BasicObject] the object to traverse
    # @yieldparam walker [Walker] the current walk
    # @yieldreturn [BasicObject] the resulting object
    # @note The block must be convertible to a shareable proc.
    def self.define(*classes, &)
      definition = Internal.prepare_method_definition(&)
      raise LocalJumpError, "no block given" unless definition
      classes.each { REGISTER.define(it) { define_method(:traverse, definition) } }
    end

    # Visit an object without automatically descending or assigning replacements.
    # @param object [BasicObject] the root object
    # @!macro walker_module_options
    #   @param constants [Boolean, Symbol] true for directly defined public constants,
    #     :inherited to include ancestors, or false to skip. Autoloads are not loaded.
    #   @param class_variables [Boolean, Symbol] true for directly defined class variables,
    #     :inherited to include ancestors, or false to skip
    # @yieldparam object [BasicObject] the current object
    # @yieldparam walker [Walker] call {#traverse}, {#skip}, or {#return} to control the walk
    # @yieldreturn [BasicObject] the result for the current object
    # @return [BasicObject] the root callback's result, or the value passed to {#return}
    # @raise [LocalJumpError] if no block is given
    def self.visit(object, constants: true, class_variables: true, &callback)
      raise LocalJumpError, "no block given" unless callback
      catch(RETURN) { new(callback, false, false, constants, class_variables).visit(object) }
    end

    # Yield each reachable object once, after its children.
    # @param object [BasicObject] the root object
    # @!macro walker_module_options
    # @yieldparam object [BasicObject] a reachable object
    # @return [BasicObject, Enumerator] the root object, or an enumerator without a block
    def self.each(object, constants: true, class_variables: true)
      return enum_for(:each, object, constants:, class_variables:) unless block_given?
      visit(object, constants:, class_variables:) do |object, walker|
        walker.traverse(object)
        yield(object)
        object
      end
    end

    # Stop at the first object for which the block is truthy.
    # Without a block, test the objects themselves.
    # @!macro walker_module_options
    # @return [Boolean]
    def self.any?(object, constants: true, class_variables: true, &)
      each(object, constants:, class_variables:).any?(&)
    end

    # Stop at the first object for which the block is falsey.
    # Without a block, test the objects themselves.
    # @!macro walker_module_options
    # @return [Boolean]
    def self.all?(object, constants: true, class_variables: true, &)
      each(object, constants:, class_variables:).all?(&)
    end

    # Transform a graph using the callback's return values.
    # Call {#traverse} to transform an object's children. Returning another value
    # replaces the object without automatically visiting that replacement.
    # Unchanged branches retain their identity, including when copy is enabled.
    # Changed cycles are connected before results are frozen or finalized.
    # A cyclic callback may run again as child replacements become known. Keep
    # callbacks repeatable and put publication or caching in {#finalize}.
    # Use {#freeze_result} instead of freezing a preliminary traversal result.
    # Data values are rebuilt only when members change, using their normal initializer.
    # Noncopyable coordination objects, such as leases, are updated in place.
    # Constants and class variables are assigned only when their value
    # changes identity. Constant replacement can emit Ruby redefinition warnings.
    # Replacing an inherited constant defines a local constant. Replacing an
    # inherited class variable updates storage shared with its owner and siblings.
    #
    # A walk is not an atomic snapshot or update. Coordinate concurrent writers
    # when transforming container structure, especially map keys.
    # @param object [BasicObject] the root object
    # @!macro walker_module_options
    # @param copy [Boolean, Symbol] false to edit mutable objects in place, true to
    #   duplicate changed objects, or a copy method such as :clone. Unchanged objects
    #   may be shared with the input. Frozen objects are cloned only when changed.
    # @param freeze [Boolean, nil] true to freeze results, false to avoid freezing them,
    #   or nil to preserve each original object's frozen state
    # @yieldparam object [BasicObject] the original object
    # @yieldparam walker [Walker] the current walk
    # @yieldreturn [BasicObject] the replacement object
    # @return [BasicObject] the transformed root, or the value passed to {#return}
    # @raise [LocalJumpError] if no block is given
    # @raise [ArgumentError] if copy is neither a boolean nor a Symbol
    # @raise [ArgumentError] if cyclic callbacks do not converge within 32 passes,
    #   or a cyclic finalizer replaces its result
    # @raise [ArgumentError] if a hash key or set element refers to a Data value
    #   still being constructed. Identity-based containers do not hash their keys.
    def self.modify(object, copy: false, freeze: nil, constants: true, class_variables: true, &callback)
      raise LocalJumpError, "no block given" unless callback

      modify =
        case copy
        when false  then true
        when true   then :dup
        when Symbol then copy
        else raise ArgumentError, "invalid value for copy: #{copy.inspect}"
        end

      catch(RETURN) { Modification.new(callback, modify, freeze, constants, class_variables).visit(object) }
    end

    # @return [false, true, Symbol] false for a read-only walk, true for in-place edits,
    #   or the selected copy method
    attr_reader :modify

    # @return [Boolean, Symbol] the constant traversal policy
    attr_reader :constants

    # @return [Boolean, Symbol] the class variable traversal policy
    attr_reader :class_variables

    # @return [BasicObject] the original object currently passed to the callback
    attr_reader :current_object

    # @!visibility private
    def initialize(callback, modify, freeze, constants, class_variables)
      { constants:, class_variables: }.each do |name, policy|
        next if [true, false, :inherited].include?(policy)
        raise ArgumentError, "invalid value for #{name}: #{policy.inspect}"
      end
      @callback        = callback
      @modify          = modify
      @freeze          = freeze
      @constants       = constants
      @class_variables = class_variables
      @visitors        = {}.compare_by_identity
      @seen            = {}.compare_by_identity
      @seen[UNDEFINED] = UNDEFINED
      @current_object  = UNDEFINED
    end

    # Visit a child, reusing the result if its identity has already been seen.
    # @param object [BasicObject] the child object
    # @return [BasicObject] the callback result or an in-progress copy for a cycle
    def visit(object)
      @seen.fetch(object) do
        current_object  = @current_object
        @current_object = object
        @seen[object]   = object # set this first to stop recursion
        @seen[object]   = catch(SKIP) do
          result        = @callback.call(object, self)
          case @modify && @freeze
          when false then result
          when true  then send_to(result, :freeze)
          else
            send_to(result, :freeze) if send_to(object, :frozen?) && !send_to(result, :frozen?)
            result
          end
        end
      ensure
        @current_object = current_object
      end
    end

    # End the current callback and use object as its result without freezing it.
    # @param object [BasicObject] the replacement, defaulting to the current object
    # @return [void]
    def skip(object = current_object) = throw(SKIP, object)

    # End the whole walk immediately.
    # @param object [BasicObject] the walk's result, defaulting to the current object
    # @return [void]
    def return(object = current_object) = throw(RETURN, object)

    # Traverse an object's children using its registered class definition.
    # @param object [BasicObject] the object to descend into, defaulting to the current object
    # @return [BasicObject] the object with transformed children when modifying
    def traverse(object = current_object)
      klass = send_to(object, :class)
      visitor = @visitors[klass] ||= REGISTER[klass]
      visitor.call(object, self)
    end

    # @api private
    def remember(object, result) = @seen[object] = result

    # Visit child values and describe how to assign their replacements.
    # The assignment block only runs during modification and may run again for cycles.
    # It receives a writable target and the resolved children. Do not mutate object
    # outside this block. Return the result of update from a traversal definition.
    # @param object [BasicObject] the object being traversed
    # @param values [Array] child references in assignment order
    # @param hash_keys [Boolean] rebuild when key descendants change in place
    # @param key_stride [Integer] spacing between keys in values, starting at zero
    # @yieldparam target [BasicObject] the writable destination
    # @yieldparam results [Array] transformed child references
    # @return [BasicObject] the traversal result
    def update(object, values, hash_keys: false, key_stride: 1) # rubocop:disable Lint/UnusedMethodArgument
      values.each { visit(it) }
      object
    end

    # Request freezing after the current result is settled.
    # With copying enabled, mutable inputs are copied before freezing.
    # @return [BasicObject] the current destination
    # @raise [ArgumentError] outside a modifying walk
    def freeze_result = raise(ArgumentError, "freeze_result requires a modifying walk")

    # Register a finalizer for the current node. It runs once after resolution
    # and requested freezing. Registering another finalizer replaces the first.
    # Cyclic finalizers must preserve identity. Acyclic finalizers may return a
    # canonical replacement, which is propagated to the parent.
    # @yieldparam result [BasicObject] the settled result
    # @yieldparam cyclic [Boolean] whether the node belongs to a cycle
    # @yieldreturn [BasicObject] the final result
    # @return [BasicObject] the current destination
    # @raise [ArgumentError] outside a modifying walk
    # @raise [LocalJumpError] if no block is given
    def finalize(&) = raise(ArgumentError, "finalize requires a modifying walk")

    # @api private
    def rebuild_data(object)
      object.class.members.each { visit(object.__send__(it)) }
      object
    end

    # Whether a visited object or its traversed descendants changed.
    # @param object [BasicObject] the object to inspect
    # @return [Boolean] false for a read-only walk
    def changed?(object = current_object) = false # rubocop:disable Lint/UnusedMethodArgument

    # @api private
    def hashable?(_object) = true

    # @api private
    def check_hash_key(object) = object

    require "farce/walker/definitions"
    require "farce/walker/modification"
  end
end
