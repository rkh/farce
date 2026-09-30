# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module MapValueModes
      NIL_VALUE = Object.new.freeze
      TIMED_OUT = Object.new.freeze
      CANCEL_UPDATE = Object.new.freeze
      private_constant :NIL_VALUE, :TIMED_OUT, :CANCEL_UPDATE

      # @!macro modes
      # @param initial_mapping [Hash, Farce::Abstract::Map, #each, nil] initial entries with shareable keys
      # @param mode [Symbol] the default value transfer mode
      # @!macro key_normalization
      # @param compare_by_identity [Boolean] the default comparison mode for keys and values
      # @param compare_keys_by_identity [Boolean] whether keys are compared by identity
      # @param compare_values_by_identity [Boolean] whether values are compared by identity
      def initialize(initial_mapping = nil, mode: :copy, normalize_keys: nil, compare_by_identity: false,
                     compare_keys_by_identity: compare_by_identity, compare_values_by_identity: compare_by_identity)
        initial_mapping = convert_entries(initial_mapping)

        identity         = BasicObject.instance_method(:equal?)
        valid_comparison = identity.bind_call(compare_values_by_identity, true) ||
          identity.bind_call(compare_values_by_identity, false)

        raise ArgumentError, "compare_values_by_identity must be a boolean" unless valid_comparison
        @compare_values_by_identity = compare_values_by_identity

        @manager = ModeManager.new(mode:)
        @map     = new_map(compare_by_identity:, compare_keys_by_identity:, compare_values_by_identity: true)
        KeyNormalizer.prepare_concurrent(@map)

        restoring  = KeyNormalizer.restoration?(normalize_keys)
        normalizer = KeyNormalizer.build(normalize_keys, shareable: true)
        KeyNormalizer.install_concurrent(self, normalizer) unless restoring

        initial_mapping&.each { |key, value| self[key] = value }
        KeyNormalizer.install_concurrent(self, normalizer) if restoring
        super()
      end

      # The default transfer mode for values.
      # @return [Symbol]
      def mode                        = @manager.mode
      def compare_values_by_identity? = @compare_values_by_identity
      def shareable_keys?             = true
      def shareable_values?           = true
      def [](key)                     = unwrap_value(@map[key])

      def []=(key, value)
        key = @map.prepare_mutation_key(key)
        @map.store_prepared(key, wrap_value(value))
        value
      end

      def fetch(*arguments)
        unless arguments.length.between?(1, 2)
          raise ArgumentError, "wrong number of arguments (given #{arguments.length}, expected 1..2)"
        end
        key, default = arguments
        warn "block supersedes default value argument", uplevel: 1 if block_given? && arguments.length == 2
        value = @map.fetch(key) do
          return yield(key) if block_given?
          return default if arguments.length == 2
          raise KeyError.new("key not found: #{key.inspect}", receiver: self, key: key)
        end
        unwrap_value(value)
      end

      def get(key, timeout: nil, &) = unwrap_result(@map.get(key, timeout:) { TIMED_OUT }, &)

      # (see Abstract::ConcurrentMap#store)
      # @param mode [Symbol, nil] the value transfer mode, or nil to use the default
      def store(key, value, mode: nil, timeout: nil, &)
        key = @map.prepare_mutation_key(key)
        unwrap_result(@map.store_prepared(key, wrap_value(value, mode:), timeout:) { TIMED_OUT }, &)
      end

      # (see Abstract::ConcurrentMap#swap)
      # @param mode [Symbol, nil] the replacement's transfer mode, or nil to use the default
      def swap(key, replacement, mode: nil, timeout: nil, &)
        key = @map.prepare_mutation_key(key)
        unwrap_result(@map.swap_prepared(key, wrap_value(replacement, mode:), timeout:) { TIMED_OUT }, &)
      end

      # (see Abstract::ConcurrentMap#store_if_absent)
      # @param mode [Symbol, nil] the result's transfer mode, or nil to use the default
      def store_if_absent(key, mode: nil, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        @map.check_mutation
        unwrap_value(@map.store_if_absent(key, timeout:) do
          value = yield
          @map.check_mutation
          wrap_value(value, mode:)
        end)
      end

      # (see Abstract::ConcurrentMap#update)
      # @param mode [Symbol, nil] the result's transfer mode, or nil to use the default
      def update(key, mode: nil, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        @map.check_mutation
        unwrap_value(@map.update(key, timeout:) do |current|
          value = yield(unwrap_value(current))
          @map.check_mutation
          wrap_value(value, mode:)
        end)
      end

      # (see Abstract::ConcurrentMap#upsert)
      # @param mode [Symbol, nil] the value transfer mode, or nil to use the default
      def upsert(key, initial, mode: nil, timeout: nil)
        raise LocalJumpError, "no block given" unless block_given?
        @map.check_mutation
        unwrap_value(@map.update(key, timeout:) do |current|
          value = nil.equal?(current) ? initial : yield(unwrap_value(current))
          @map.check_mutation
          wrap_value(value, mode:)
        end)
      end

      # (see Abstract::ConcurrentMap#compare_and_set)
      # @param mode [Symbol, nil] the replacement's transfer mode, or nil to use the default
      def compare_and_set(key, expected, replacement, mode: nil, timeout: nil)
        key = @map.prepare_mutation_key(key)
        expected = wrap_comparison(expected)
        catch(CANCEL_UPDATE) do
          result = @map.update_prepared(key, timeout:) do |current|
            # Abort the update instead of inserting a value for a missing key.
            throw CANCEL_UPDATE, false if nil.equal?(current) || !values_equal?(current, expected)
            @map.check_mutation
            wrap_value(replacement, mode:)
          end
          !nil.equal?(result)
        end
      end

      def wait_until_changed(key, expected, timeout: nil, &)
        prepared_key = @map.normalize_external_key(key)
        expected = wrap_comparison(expected)
        deadline = Internal.timeout_deadline(timeout)
        loop do
          current = @map.get_prepared(prepared_key, timeout: Internal.remaining_timeout(deadline)) { TIMED_OUT }
          return unwrap_result(current, &) if TIMED_OUT.equal?(current)
          return unwrap_value(current) unless values_equal?(nil.equal?(current) ? NIL_VALUE : current, expected)
          result = @map.wait_until_changed_prepared(
            prepared_key,
            current,
            timeout: Internal.remaining_timeout(deadline),
          ) { TIMED_OUT }
          return unwrap_result(result, &) if TIMED_OUT.equal?(result)
        end
      end

      def wait_until_non_nil(key, timeout: nil, &) = wait_until_changed(key, nil, timeout:, &)
      def delete(key) = unwrap_value(@map.delete(key))

      def each
        return enum_for(__method__) { size } unless block_given?
        @map.each { |key, value| yield [key, unwrap_value(value)] }
        self
      end
      alias each_pair each

      def each_live
        return enum_for(__method__) { size } unless block_given?
        @map.each_live { |key, value| yield [key, unwrap_value(value)] }
        self
      end

      def each_value
        return enum_for(__method__) { size } unless block_given?
        @map.each_value { |value| yield unwrap_value(value) }
        self
      end

      protected

      def wrap_value(value, mode: nil) = nil.equal?(value) ? NIL_VALUE : @manager.wrap(value, mode:)
      def unwrap_value(value)          = NIL_VALUE.equal?(value) ? nil : @manager.unwrap(value)

      private

      def check_key(key)
        return if Ractor.shareable?(key)
        raise Ractor::IsolationError, "key must be Ractor-shareable"
      end

      def wrap_comparison(value) = wrap_value(value, mode: compare_values_by_identity? ? :local : :copy)

      def unwrap_result(result)
        return unwrap_value(result) unless TIMED_OUT.equal?(result)
        yield if block_given?
      end

      def values_equal?(left, right) = @manager.same_value?(left, right, identity: compare_values_by_identity?)
    end
  end
end
