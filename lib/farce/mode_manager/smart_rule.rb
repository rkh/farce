# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class ModeManager
    # Class for converting values based on smart rules.
    class SmartRule
      SMART_MODES = %i[smart smart_raise smart_move smart_copy].freeze
      private_constant :SMART_MODES

      include Shareable::Immutable

      # @note This method must be called from the main ractor.
      # Allows you to add rules for smart wrapping of specific classes.
      #
      # @overload define(klass, mode = nil)
      #   @example
      #     # Have smart modes use the :make_shareable mode for instances of MyClass
      #     Farce::ModeManager::SmartRule.define(MyClass, :make_shareable)
      #
      #   @param klass [Class] the class to define a smart wrapping rule for
      #   @param mode [Symbol] the mode to use when wrapping instances of the class
      #
      # @overload define(klass)
      #   @example
      #     # Have smart modes use a custom block for instances of MyClass
      #     Farce::ModeManager::SmartRule.define(MyClass) do |value, mode_manager|
      #       raise Ractor::Error, "#{value.inspect} cannot be shared" if value.dont_share?
      #       mode_manager.wrap(value, mode: :make_shareable)
      #     end
      #
      #   @param klass [Class] the class to define a smart wrapping rule for
      #   @yield [value, mode_manager, mode] The block will be called when wrapping an instance of klass.
      #   @yieldparam value [BasicObject] The value being wrapped.
      #   @yieldparam mode_manager [Farce::ModeManager] The mode manager instance.
      #   @yieldparam mode [Symbol] The mode to use when wrapping the value, like `:smart` or `:smart_copy`.
      #   @yieldreturn [BasicObject] The shareable version of the value.
      #
      # @overload define(klass)
      #   @example
      #     Farce::ModeManager::SmartRule.define(MyClass) do
      #       def smart_copy(value, mode_manager) = mode_manager.wrap(value, mode: :copy)
      #       def smart_move(value, mode_manager) = mode_manager.wrap(value, mode: :move)
      #     end
      #
      #   @yield block used for defining different methods for different smart modes.
      #   @yieldreceiver [Class] The {SmartRule} subclass.
      #
      # @return [Class] the defined smart rule class.
      def self.define(klass, mode = nil, &block)
        SMART_RULES.define(klass) do
          if mode
            class_eval <<~RUBY, __FILE__, __LINE__ + 1
              def call(value, mode_manager, _) = mode_manager.wrap(value, mode: #{mode.inspect})
            RUBY
          end

          if block_given?
            if block.arity.zero?
              class_eval(&block)
              SMART_MODES.each { private it if method_defined?(it) }
            else
              define_method(:call, &Ractor.shareable_lambda(&block))
            end
          end
        end
      end

      # @api private
      def call(value, mode_manager, mode)
        register = mode_manager.register || Proxy.default_register
        return Proxy.new(value, register:) if register.dedicated_proxy?(value.class)
        __send__(mode, value, mode_manager)
      rescue TypeError => e
        raise unless e.message.include?("allocator undefined for")
        raise Ractor::IsolationError, "#{value.inspect} cannot be shared"
      end

      # @api private
      def marshal_dump = raise TypeError, "smart rules cannot be marshaled"

      private

      # smart is intentionally not an alias
      def smart(value, mode_manager)      = smart_raise(value, mode_manager)
      def smart_raise(value, _)           = raise Ractor::IsolationError, "#{value.inspect} cannot be shared"
      def smart_move(value, mode_manager) = mode_manager.wrap(value, mode: :move)

      def smart_copy(value, mode_manager)
        mode_manager.wrap(value, mode: :copy)
      rescue StandardError => e
        begin
          mode_manager.wrap(value, mode: :marshal)
        rescue StandardError
          raise e, cause: e.cause
        end
      end
    end

    SMART_RULES = ClassMirror.new(SmartRule) { |klass, _| klass.new }
    private_constant :SMART_RULES

    SmartRule.define(Time, :make_shareable)

    [Array, ::Set].each do |klass|
      SmartRule.define(klass) do
        def smart_copy(value, mode_manager)
          all_shareable = true
          mapped = value.dup.map! do |entry|
            result = mode_manager.wrap(entry, mode: :smart_raise)
            if mode_manager.managed_envelope?(result)
              all_shareable = false
              entry
            else
              result
            end
          rescue StandardError
            all_shareable = false
            entry
          end
          return super unless all_shareable
          Ractor.make_shareable(mapped)
        end

        def smart(value, mode_manager)
          return super unless value.all? { Ractor.shareable?(it) }
          Ractor.make_shareable(value)
        end
      end
    end

    SmartRule.define(Hash) do |value, mode_manager, mode|
      return super(value, mode_manager, mode) unless value.all? { _1.is_a?(Symbol) && Ractor.shareable?(_2) }
      Ractor.make_shareable(value)
    end
  end
end
