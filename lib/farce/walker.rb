# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # Visit or transform an object graph without revisiting the same object.
  # Traversal follows container elements, hash keys and values, and ordinary
  # instance variables. Farce containers expose their contents, not their storage.
  # Proc traversal follows the receiver, not captured local variables.
  #
  # {.visit} and {.modify} let the callback choose when to descend with {#traverse}.
  # {.each} descends automatically and yields children before their parent.
  # Shared children and cycles are tracked by identity.
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

      def call(object, walker)
        prepared = walker.modify ? prepare_modification(object, walker) : object
        # Publish the copy before descending so back references find the copy.
        walker.remember(object, prepared)
        traverse(prepared, walker)
      end

      private

      def prepare_modification(object, walker)
        return object unless Internal.garbage_collectable?(object)
        # Data traversal allocates its replacement before visiting members and
        # initializes it afterward. A normal dup is already frozen.
        return object if Data === object
        return object if Internal::Noncopyable === object || Abstract::LeaseMap === object
        case walker.modify
        when true   then send_to(object, :frozen?) ? object.clone(freeze: false) : object
        when :dup   then send_to(object, :dup)
        when :clone then send_to(object, :clone, freeze: false)
        else             send_to(object, walker.modify)
        end
      end
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
    # The object is already prepared for modification. Visit each child with
    # {#visit} and assign its result only when {#modify} is truthy.
    #
    # Should only be necessary for classes using storage defined outside of Ruby (like a C struct).
    #
    # @example
    #   # Lets assume NativeClass has a natively stored value
    #   Farce::Walker.define(NativeClass) do |object, walker|
    #     value        = object.value
    #     result       = walker.visit(value)
    #     object.value = result if walker.modify && !value.equal?(result)
    #     object
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
    # @yieldparam object [BasicObject] the current object
    # @yieldparam walker [Walker] call {#traverse}, {#skip}, or {#return} to control the walk
    # @yieldreturn [BasicObject] the result for the current object
    # @return [BasicObject] the root callback's result, or the value passed to {#return}
    # @raise [LocalJumpError] if no block is given
    def self.visit(object, &callback)
      raise LocalJumpError, "no block given" unless callback
      catch(RETURN) { new(callback, false, false).visit(object) }
    end

    # Yield each reachable object once, after its children.
    # @param object [BasicObject] the root object
    # @yieldparam object [BasicObject] a reachable object
    # @return [BasicObject, Enumerator] the root object, or an enumerator without a block
    def self.each(object)
      return enum_for(:each, object) unless block_given?
      visit(object) do |object, walker|
        walker.traverse(object)
        yield(object)
        object
      end
    end

    # Stop at the first object for which the block is truthy.
    # Without a block, test the objects themselves.
    # @return [Boolean]
    def self.any?(object, &) = each(object).any?(&)

    # Stop at the first object for which the block is falsey.
    # Without a block, test the objects themselves.
    # @return [Boolean]
    def self.all?(object, &) = each(object).all?(&)

    # Transform a graph using the callback's return values.
    # Call {#traverse} to transform an object's children. Returning another value
    # replaces the object without automatically visiting that replacement.
    # Copies are recorded before their children are visited to preserve cycles.
    # Data values are rebuilt through allocation and their normal initializer.
    # Noncopyable coordination objects, such as leases, are updated in place.
    #
    # A walk is not an atomic snapshot or update. Coordinate concurrent writers
    # when transforming container structure, especially map keys.
    # @param object [BasicObject] the root object
    # @param copy [Boolean, Symbol] false to edit mutable objects in place, true for dup,
    #   or a copy method such as :clone. Frozen objects are cloned before in-place edits.
    # @param freeze [Boolean, nil] true to freeze results, false to avoid freezing them,
    #   or nil to preserve each original object's frozen state
    # @yieldparam object [BasicObject] the original object
    # @yieldparam walker [Walker] the current walk
    # @yieldreturn [BasicObject] the replacement object
    # @return [BasicObject] the transformed root, or the value passed to {#return}
    # @raise [LocalJumpError] if no block is given
    # @raise [ArgumentError] if copy is neither a boolean nor a Symbol
    # @raise [ArgumentError] if a hash key or set element refers to a Data value
    #   still being constructed. Identity-based containers do not hash their keys.
    def self.modify(object, copy: false, freeze: nil, &callback)
      raise LocalJumpError, "no block given" unless callback

      modify =
        case copy
        when false  then true
        when true   then :dup
        when Symbol then copy
        else raise ArgumentError, "invalid value for copy: #{copy.inspect}"
        end

      catch(RETURN) { new(callback, modify, freeze).visit(object) }
    end

    # @return [false, true, Symbol] false for a read-only walk, true for in-place edits,
    #   or the selected copy method
    attr_reader :modify

    # @return [BasicObject] the original object currently passed to the callback
    attr_reader :current_object

    # @!visibility private
    def initialize(callback, modify, freeze)
      @callback        = callback
      @modify          = modify
      @freeze          = freeze
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
    def traverse(object = current_object) = REGISTER[send_to(object, :class)].call(object, self)

    # @api private
    def remember(object, result) = @seen[object] = result

    # @api private
    def rebuild_data(object)
      result = object.class.allocate
      remember(object, result)
      unfinished = @unfinished_data ||= {}.compare_by_identity
      unfinished[object] = unfinished[result] = true
      begin
        result.__send__(:initialize, **yield)
        result
      ensure
        unfinished.delete(object)
        unfinished.delete(result)
      end
    end

    # @api private
    def hashable?(object)
      return true unless @unfinished_data && !@unfinished_data.empty?

      # Check identities before descending. Some engines cannot even read the
      # members of an allocated Data value until its initializer has run.
      !self.class.visit(object) do |value, traversal|
        traversal.return(true) if @unfinished_data.key?(value)
        traversal.traverse
        false
      end
    end

    # @api private
    def check_hash_key(object)
      return object if hashable?(object)
      raise ArgumentError, "hash key or set element refers to an unfinished Data value"
    end

    require "farce/walker/definitions"
  end
end
