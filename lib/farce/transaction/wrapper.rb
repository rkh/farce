# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Transaction
    # Binds container wrappers to the transaction attempt that created them.
    #
    # Wrappers call {#access} or {#write} around operations on staged data.
    # These checks reject calls from another Fiber or after the attempt ends.
    # They also invalidate the attempt when an operation raises, so rescuing
    # the error cannot publish writes staged before that failed operation.
    #
    # @api private
    module Wrapper
      # Wrappers inherit abstract container classes for their interfaces, but
      # must not initialize another ordinary container. This constructor ends
      # Unshareable's super chain after binding the existing transaction snapshot.
      module Initialization
        # Bind the wrapper to its participant and active attempt.
        # Enroll backend when the wrapper owns storage. Composite wrappers use
        # other wrappers for their snapshots and leave backend nil.
        # @param transaction [Transaction] the current attempt
        # @param object [Object] the original participant
        # @param backend [Object, nil] the participant's storage to enroll, if any
        # @param manager [ModeManager, nil] the participant's value transfer manager
        # @param nil_value [BasicObject, nil] the backend's sentinel for stored nil
        def initialize(transaction, object, backend = nil, manager: nil, nil_value: nil)
          @transaction = transaction
          @object      = object
          @backend     = backend
          @manager     = manager
          @nil_value   = nil_value
          @entry       = enlist(backend) if backend
          @working     = @entry&.working
        end
      end
      private_constant :Initialization

      include Initialization
      include Unshareable

      # Allow transaction[wrapper] to reuse a wrapper from this same attempt.
      # A different attempt cannot adopt its snapshot or staged writes.
      # @param transaction [Transaction] the attempt requesting the wrapper
      # @return [self]
      # @raise [TypeError] if the wrapper belongs to a different attempt
      def transaction_wrapper(transaction)
        access do
          raise TypeError, "wrapper belongs to another transaction" unless @transaction.equal?(transaction)
          self
        end
      end

      # Select the abstract container helpers that can operate on staged data.
      # Each wrapper supplies its supported helpers. Other inherited operations
      # may wait on live storage, copy the participant, or bypass its snapshot.
      #
      # @param klass [Class] the wrapper class to configure
      # @param helpers [Array<Symbol>] inherited reads to retain and guard
      # @param writes [Array<Symbol>] inherited writes that must also check the
      #   original participant's frozen state
      # @return [Class] the configured wrapper class
      def self.inherit(klass, *helpers, writes: [])
        helpers += writes
        owners     = klass.ancestors.take_while { |ancestor| ancestor != klass.superclass }
        own        = klass.public_instance_methods.select { owners.include?(klass.instance_method(it).owner) }
        enumerable = klass <= Enumerable ? Enumerable.public_instance_methods : []

        # Set and Vector override map/select to construct self.class. Use
        # Enumerable's Array results so these calls do not construct wrappers
        # without a transaction and participant.
        enumerable.each do |name|
          next if own.include?(name) || helpers.include?(name)
          klass.define_method(name, Enumerable.instance_method(name))
        end

        guards   = Module.new
        rejected = klass.superclass.public_instance_methods - Object.public_instance_methods -
          enumerable - helpers - own
        rejected.each { |name| klass.class_eval { undef_method(name) } }

        # Metadata reads and empty-input calls can return without touching
        # storage. Guard the helper itself so these also reject closed attempts.
        helpers.each do |name|
          next if own.include?(name)
          operation = writes.include?(name) ? :write : :access
          guards.module_eval <<~RUBY, __FILE__, __LINE__ + 1
            def #{name}(...)
              #{operation} { super }
            end
          RUBY
        end
        klass.prepend(guards)
      end

      private

      def enlist(backend) = @transaction.enlist(backend)

      # Initialize a composite wrapper after binding it to the participant.
      # Copy the named settings, then replace each storage field with its
      # wrapper from this attempt. Set uses this to retain membership settings
      # while its map handles snapshots and commit validation.
      # @param settings [Array<Symbol>] participant instance variables, without @
      # @param components [Hash{Symbol => Object}] storage fields, without @,
      #   and the original objects to wrap
      def compose(*settings, **components)
        settings.each do |name|
          variable = :"@#{name}"
          instance_variable_set(variable, @object.instance_variable_get(variable))
        end
        components.each { |name, object| instance_variable_set(:"@#{name}", @transaction[object]) }
      end

      # A rescued NoMethodError must still discard earlier staged writes.
      # Local wrappers retain the participant's scope getter, with the same
      # lifetime check as reads of staged values.
      def method_missing(name, *arguments, **options, &block)
        if name == :scope && arguments.empty? && options.empty? && !block && @object.respond_to?(:scope)
          return access { @object.scope }
        end
        @transaction.fail!(retryable: false)
        super
      end

      def respond_to_missing?(name, include_private = false)
        (name == :scope && @object.respond_to?(:scope)) || super
      end

      def require_block!(present)
        return if present
        @transaction.fail!(retryable: false)
        raise LocalJumpError, "no block given"
      end

      def access
        @transaction.check_open!
        yield
      rescue Internal::TransactionConflict
        @transaction.fail! if @transaction.state == :active
        raise
      rescue Exception # rubocop:disable Lint/RescueException -- cancellation must poison the attempt too
        @transaction.fail!(retryable: false) if @transaction.state == :active
        raise
      end

      def initialize_copy(*)
        access do
          @transaction.fail!(retryable: false)
          raise TypeError, "transaction wrappers cannot be copied"
        end
      end

      def check_frozen! = Internal::Freeze.check(@object)

      def write
        access do
          raise FrozenError, "cannot modify frozen transaction participant" if @object.frozen?
          @transaction.guard(@object)
          @entry&.write!
          yield
        end
      end

      def wrap(value, mode: nil)
        return @nil_value if value.nil? && @nil_value
        return value unless @manager
        selected = mode || @manager.mode

        # These modes can change ownership or freeze supplied objects before
        # commit. Discarding staged storage cannot undo those effects.
        if %i[move make_shareable dedup proxy].include?(selected)
          raise TypeError, "#{selected} transfers do not support transactions"
        end

        @manager.wrap(value, mode:)
      end

      def unwrap_stored(value)
        return if @nil_value.equal?(value)
        return value unless @manager
        raise TypeError, "move envelopes do not support transactions" if Envelope::Move === value
        @manager.unwrap(value)
      end

      def matches?(current, expected, identity:)
        comparison = @manager.wrap(expected, mode: identity ? :local : :copy)
        comparison = @nil_value if expected.nil? && @nil_value
        @manager.same_value?(current, comparison, identity:)
      end

      def compared(result)
        @transaction.fail! unless result
        result
      end
    end
  end
end
