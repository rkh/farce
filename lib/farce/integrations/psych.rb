# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group Psych Integration
require "farce"
require "psych" unless defined?(Psych::Coder)

module Farce
  class Abstract::Map
    # @api private
    # Called by Psych for generating YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [Psych::Coder] The coder containing the serialized fields.
    def encode_with(coder)
      coder["entries"]                    = to_h
      coder["compare_values_by_identity"] = compare_values_by_identity?
      coder["compare_keys_by_identity"]   = compare_keys_by_identity?
      normalizer = instance_variable_get(:@key_normalizer)
      coder["normalize_keys"] = Internal::KeyNormalizer.dump(normalizer) if normalizer
      coder["scope"] = scope if respond_to?(:scope)
      coder
    end

    # @api private
    # Called by Psych when parsing YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [void]
    def init_with(coder)
      options = coder.map.except("entries").transform_keys(&:to_sym)
      if options.key?(:normalize_keys)
        options[:normalize_keys] =
          Internal::KeyNormalizer.restore(options[:normalize_keys])
      end
      initialize(coder["entries"], **options)
    end
  end

  class Abstract::BoundedMap
    # @api private
    # Called by Psych for generating YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [Psych::Coder] The coder containing the serialized fields.
    def encode_with(coder) = super.tap { it["max_size"] = max_size }
  end

  module Internal::ValueSerialization
    # @api private
    # Called by Psych for generating YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [Psych::Coder] The coder containing the serialized fields.
    def encode_with(coder)
      coder["value"] = value
      coder["scope"] = scope if respond_to?(:scope)
      coder
    end

    # @api private
    # Called by Psych when parsing YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [void]
    def init_with(coder)
      options = coder.map.except("value").transform_keys(&:to_sym)
      initialize(coder["value"], **options)
    end
  end

  class Abstract::Atom
    # @api private
    # Called by Psych for generating YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [Psych::Coder] The coder containing the serialized fields.
    def encode_with(coder)
      super
      coder["compare_by_identity"] = compare_by_identity?
      coder["shareable"]           = Ractor.shareable?(coder["value"])
      coder
    end

    # @api private
    # Restore the value and its shareability when parsing YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [void]
    def init_with(coder)
      value   = coder["value"]
      value   = Ractor.make_shareable(value) if coder["shareable"]
      options = coder.map.except("value", "shareable").transform_keys(&:to_sym)
      initialize(value, **options)
    end
  end

  module Abstract::Counter
    # @api private
    # Called by Psych for generating YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [Psych::Coder] The coder containing the serialized fields.
    def encode_with(coder)
      super
      coder["initial"] = initial
      coder
    end

    # @api private
    # Called by Psych when parsing YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [void]
    def init_with(coder)
      options = coder.map.except("value", "initial").transform_keys(&:to_sym)
      initialize(coder["initial"], **options)
      self.value = coder["value"]
    end
  end

  class Atom
    # @api private
    # Called by Psych for generating YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [Psych::Coder] The coder containing the serialized fields.
    def encode_with(coder)
      super
      coder["mode"] = mode
      coder
    end
  end

  class Abstract::Set
    # @api private
    # Called by Psych for generating YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [Psych::Coder] The coder containing the set representation.
    def encode_with(coder)
      coder["entries"] = each_stored.map do |key, stored|
        element        = public_stored(key, stored)
        entry          = {
          "value"     => element,
          "shareable" => Ractor.shareable?(element),
        }
        if value_modes?
          entry["identity"] = identity_storage_key?(key)
          entry["snapshot"] = key unless entry["identity"]
          entry["mode"]     = stored_mode(stored)
        end
        entry
      end
      coder["compare_by_identity"] = compare_by_identity?
      coder["frozen"]              = frozen?
      coder["mode"]                = mode if respond_to?(:mode)
      coder["scope"]               = scope if respond_to?(:scope)
      coder["normalize"]           = Internal::KeyNormalizer.dump(@normalizer) if @normalizer
      coder
    end

    # @api private
    # Called by Psych when parsing YAML.
    # @param coder [Psych::Coder] The YAML representation.
    # @return [self] The restored set.
    def init_with(coder)
      options             = { compare_by_identity: coder["compare_by_identity"] }
      options[:mode]      = coder["mode"].to_sym                                if coder["mode"]
      options[:scope]     = coder["scope"].to_sym                               if coder["scope"]
      options[:normalize] = Internal::KeyNormalizer.restore(coder["normalize"]) if coder.map.key?("normalize")
      entries             = coder["entries"]

      if coder["mode"] && value_modes?
        initialize(nil, **options)
        entries.each { restore_yaml_entry(it) }
      else
        values = entries.map { restore_yaml_value(it) }
        initialize(values, **options)
      end

      freeze if coder["frozen"]
      self
    end

    private

    def restore_yaml_entry(entry)
      value   = restore_yaml_value(entry)
      key     = entry["identity"] ? comparison_key_for_canonical(value) : Ractor.make_shareable(entry["snapshot"])
      mode    = entry["mode"]&.to_sym
      payload = @manager.wrap(value, mode:)
      add_stored(key, StoredEntry.new(@manager, payload))
    end

    def restore_yaml_value(entry)
      value = entry["value"]
      entry["shareable"] ? Ractor.make_shareable(value) : value
    end
  end
end
