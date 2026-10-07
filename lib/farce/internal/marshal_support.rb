# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal # :nodoc: all
    # Portable snapshots of public values. Backing stores never enter the stream.
    module MarshalSupport
      extend self

      def protocol_method?(name) = %i[marshal_dump marshal_load _dump _load _dump_data _load_data].include?(name)

      # A version belongs to the public snapshot, not to a backend layout.
      def payload(data, length)
        unless data.is_a?(Array) && data.length == length + 1 && data.first == 1
          raise TypeError, "invalid Farce Marshal snapshot"
        end
        data.drop(1)
      end

      def value(value) = [Internal.marshal_shareable?(value), Kernel.instance_method(:frozen?).bind_call(value), value]

      def restore_value(data)
        shareable, frozen, value = data
        if shareable && Shareable === value && !(Shareable::Native === value) &&
            !Kernel.instance_method(:frozen?).bind_call(value) &&
            value.respond_to?(:marshal_load, true) && value.method(:marshal_load).owner.name&.start_with?("Farce::")
          raise TypeError, "recursive shareable snapshots require an initialized value"
        end
        value = Ractor.make_shareable(value) if shareable
        Kernel.instance_method(:freeze).bind_call(value) if frozen
        value
      end

      def freeze(object, frozen)
        return object unless frozen
        object.freeze
      end

      module Initialize
        private

        # @api private
        def marshal_initialize(arguments, options, _configuration = nil)
          initialize(*arguments, **options)
        end

        # @api private
        def marshal_configuration = nil

        # A restored manager must retain its links to already-loaded envelopes.
        # @api private
        def marshal_mode_manager(mode) = @manager || ModeManager.new(mode:)

        def publish_marshaled
          if is_a?(Shareable)
            publish_shareable
          elsif is_a?(Unshareable)
            pin_unshareable
          end
        end
      end

      module Counter
        include Initialize

        # @api private
        def marshal_dump
          options = respond_to?(:scope) ? { scope: } : {}
          [1, initial, value, options, marshal_configuration, frozen?]
        end

        # @api private
        def marshal_load(data)
          initial, current, options, configuration, frozen = MarshalSupport.payload(data, 5)
          marshal_initialize([initial], options, configuration)
          store(current)
          MarshalSupport.freeze(self, frozen)
        end
      end

      module Flag
        include Initialize

        # @api private
        def marshal_dump
          options = respond_to?(:scope) ? { scope: } : {}
          [1, value, options, marshal_configuration, frozen?]
        end

        # @api private
        def marshal_load(data)
          current, options, configuration, frozen = MarshalSupport.payload(data, 4)
          marshal_initialize([current], options, configuration)
          MarshalSupport.freeze(self, frozen)
        end
      end

      module Atom
        include Initialize

        # @api private
        def marshal_dump
          options = { compare_by_identity: compare_by_identity? }
          options[:mode] = mode if respond_to?(:mode)
          options[:scope] = scope if respond_to?(:scope)
          [1, MarshalSupport.value(value), options, marshal_configuration, frozen?]
        end

        # @api private
        def marshal_load(data)
          current, options, configuration, frozen = MarshalSupport.payload(data, 4)
          marshal_initialize([nil], options, configuration)
          store(MarshalSupport.restore_value(current))
          MarshalSupport.freeze(self, frozen)
        end
      end

      module Vector
        include Initialize

        # @api private
        def marshal_dump
          options = { compare_by_identity: compare_by_identity? }
          options[:scope] = scope if respond_to?(:scope)
          [1, internal_vector.snapshot.map { MarshalSupport.value(it) }, options, marshal_configuration, frozen?]
        end

        # @api private
        def marshal_load(data)
          entries, options, configuration, frozen = MarshalSupport.payload(data, 4)
          marshal_initialize([[]], options, configuration)
          entries.each { internal_vector.push(MarshalSupport.restore_value(it)) }
          MarshalSupport.freeze(self, frozen)
        end
      end

      module Map
        include Initialize

        # @api private
        def marshal_dump
          options = {}
          unless is_a?(Abstract::TreeMap)
            options[:compare_keys_by_identity] = compare_keys_by_identity?
            options[:compare_values_by_identity] = compare_values_by_identity?
          end
          options[:mode] = mode if respond_to?(:mode)
          options[:manager] = @manager if defined?(@manager) && !@manager.is_a?(WeakModeManager)
          options[:scope] = scope if respond_to?(:scope)
          options[:max_size] = max_size if respond_to?(:max_size)
          options[:normalize_keys] = KeyNormalizer.dump(@key_normalizer) if @key_normalizer
          entries = marshal_entries.map do |key, stored|
            [MarshalSupport.value(key), marshal_map_value(stored)]
          end
          [1, entries, options, marshal_configuration, frozen?]
        end

        # @api private
        def marshal_load(data)
          entries, options, configuration, frozen = MarshalSupport.payload(data, 4)
          @manager = options.delete(:manager) if options.key?(:manager)
          options[:normalize_keys] = KeyNormalizer.restore(options[:normalize_keys]) if options.key?(:normalize_keys)
          marshal_initialize([nil], options, configuration)
          map = marshal_map
          entries.each do |key, stored|
            map[MarshalSupport.restore_value(key)] = marshal_restore_map_value(stored)
          end
          MarshalSupport.freeze(self, frozen)
        end

        private

        # @api private
        def marshal_entries = marshal_map.each

        # @api private
        def marshal_map
          map = internal_map
          KeyNormalizer::ConcurrentMap === map ? map.transaction_source : map
        end

        # @api private
        def marshal_map_value(value)
          MarshalSupport.value(value)
        end

        # @api private
        def marshal_restore_map_value(data)
          MarshalSupport.restore_value(data)
        end
      end

      module Reject
        # @api private
        def marshal_dump = raise(TypeError, "#{self.class} cannot be marshaled")
      end

      module WeakValue
        # @api private
        def marshal_dump
          state, current = state_and_value
          raise TypeError, "moved weak values cannot be marshaled" if state == :moved
          [1, MarshalSupport.value(current), frozen?]
        end

        # @api private
        def marshal_load(data)
          current, frozen = MarshalSupport.payload(data, 2)
          initialize(MarshalSupport.restore_value(current))
          freeze if frozen
        end
      end

      module WeakRef
        # @api private
        def marshal_dump = [1, @value]

        # @api private
        def marshal_load(data)
          @value, = MarshalSupport.payload(data, 1)
          Kernel.instance_method(:freeze).bind_call(self)
        end
      end
    end
  end
end
