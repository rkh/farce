# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Walker
    define(BasicObject) do |object, walker|
      send_to(object, :instance_variables).each do |ivar|
        value  = send_to(object, :instance_variable_get, ivar)
        result = walker.visit(value)
        next unless walker.modify && !value.equal?(result)

        send_to(object, :instance_variable_set, ivar, result)
      end

      object
    end

    define(Module) do |object, walker|
      if walker.constants
        Internal.walker_constants(object, walker.constants == :inherited).each do |name|
          next if object.autoload?(name, walker.constants == :inherited)

          value  = object.const_get(name, walker.constants == :inherited)
          result = walker.visit(value)
          object.const_set(name, result) if walker.modify && !value.equal?(result)
        end
      end

      if walker.class_variables
        object.class_variables(walker.class_variables == :inherited).each do |name|
          value  = object.class_variable_get(name)
          result = walker.visit(value)
          object.class_variable_set(name, result) if walker.modify && !value.equal?(result)
        end
      end

      super(object, walker)
    end

    define(Internal::Atom, Abstract::Atom) do |object, walker|
      value  = object.value
      result = walker.visit(value)
      object.value = result if walker.modify && !value.equal?(result)
      object
    end

    define(Array, Internal::Vector, Abstract::Vector) do |object, walker|
      index = 0
      values = Internal::Vector === object ? object.snapshot : object
      values.each do |value|
        result = walker.visit(value)
        object[index] = result if walker.modify && !value.equal?(result)
        index += 1
      end

      Array === object ? super(object, walker) : object
    end

    define(::Set, Abstract::Set) do |object, walker|
      # Rebuild from a snapshot so replacements can overlap existing elements.
      values = object.to_a.map { walker.visit(it) }
      if walker.modify
        values.each { walker.check_hash_key(it) } unless object.compare_by_identity?
        object.clear
        values.each { object.add(it) }
      end
      object
    end

    define(Hash, Abstract::Map) do |object, walker|
      entries = object.each.map { |key, value| [walker.visit(key), walker.visit(value)] }
      if walker.modify
        identity = Hash === object ? object.compare_by_identity? : object.compare_keys_by_identity?
        entries.each { |entry| walker.check_hash_key(entry.first) } unless identity
        # Deleting all old keys first also handles swaps and in-place key changes.
        object.clear
        entries.each { |key, value| object[key] = value }
      end

      Hash === object ? super(object, walker) : object
    end

    define(Abstract::ConcurrentMap) do |object, walker|
      entries = []
      object.each do |key, value|
        new_key = walker.visit(key)
        result  = walker.visit(value)
        next unless walker.modify
        walker.check_hash_key(new_key) unless object.compare_keys_by_identity?

        if !key.equal?(new_key)
          entries << [key, new_key, result]
        elsif !value.equal?(result)
          until object.compare_and_set(key, value, result)
            value  = object[key]
            result = walker.visit(value)
          end
        end
      end

      # All removals must precede insertions because replacement keys may overlap.
      entries.each { |key, _, _| object.delete(key) }
      entries.each { |_, key, value| object[key] = value } # rubocop:disable Style/CombinableLoops
      object
    end

    define(Abstract::LeaseMap) do |object, walker|
      object.auto_lease do
        entries = object.keys.map { |key| [key, walker.visit(key), walker.visit(object[key])] }
        if walker.modify
          entries.each { |_, key, _| walker.check_hash_key(key) } unless object.compare_keys_by_identity?
          entries.each { |key, new_key, _| object.delete(key) unless key.equal?(new_key) }
          entries.each { |_, key, value| object[key] = value } # rubocop:disable Style/CombinableLoops
        end
      end
      object
    end

    define(Abstract::Lease) do |object, walker|
      value   = object.checkout
      success = true
      result  = walker.visit(value)
      value   = result if walker.modify
      object
    ensure
      object.checkin(value) if success
    end

    define(Proc) do |object, walker|
      if Internal.rebindable?(object)
        value  = object.binding.receiver
        result = walker.visit(value)
        object = Farce.rebind(object, self: result) if walker.modify && !value.equal?(result)
      end

      super(object, walker)
    end

    define(Data) do |object, walker|
      unless walker.modify
        object.members.each { walker.visit(object.__send__(it)) }
        next object
      end

      # Allocation gives us an identity for back references. Data#initialize
      # installs the transformed members and freezes the completed value.
      walker.rebuild_data(object) do
        object.members.to_h { |member| [member, walker.visit(object.__send__(member))] }
      end
    end
  end
end
