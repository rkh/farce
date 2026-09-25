# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Walker
    define(BasicObject) do |object, walker|
      names = send_to(object, :instance_variables)
      next object if names.empty?
      unless walker.modify
        names.each { walker.visit(send_to(object, :instance_variable_get, it)) }
        next object
      end
      values = names.map { send_to(object, :instance_variable_get, it) }
      walker.update(object, values) do |target, results|
        names.each_with_index do |name, index|
          next if send_to(target, :instance_variable_get, name).equal?(results[index])
          send_to(target, :instance_variable_set, name, results[index])
        end
        target
      end
    end

    define(Module) do |object, walker|
      if walker.constants
        inherit = walker.constants == :inherited
        constant_names = Internal.walker_constants(object, inherit).reject { object.autoload?(it, inherit) }
        values = constant_names.map { object.const_get(it, inherit) }
        object = walker.update(object, values) do |target, results|
          constant_names.each_with_index do |name, index|
            target.const_set(name, results[index]) unless target.const_get(name, inherit).equal?(results[index])
          end
          target
        end
      end
      if walker.class_variables
        variable_names = object.class_variables(walker.class_variables == :inherited)
        values = variable_names.map { object.class_variable_get(it) }
        object = walker.update(object, values) do |target, results|
          variable_names.each_with_index do |name, index|
            unless target.class_variable_get(name).equal?(results[index])
              target.class_variable_set(name,
                results[index])
            end
          end
          target
        end
      end
      super(object, walker)
    end

    define(Internal::Atom, Abstract::Atom) do |object, walker|
      walker.update(object, [object.value]) do |target, results|
        target.value = results.first unless target.value.equal?(results.first)
        target
      end
    end

    define(Array, Internal::Vector, Abstract::Vector) do |object, walker|
      unless walker.modify
        values = Internal::Vector === object ? object.snapshot : object
        values.each { walker.visit(it) }
        next(Array === object ? super(object, walker) : object)
      end
      values = Internal::Vector === object ? object.snapshot : object.to_a
      result = walker.update(object, values) do |target, results|
        results.each_with_index { |value, index| target[index] = value unless target[index].equal?(value) }
        target
      end
      Array === object ? super(result, walker) : result
    end

    define(::Set, Abstract::Set) do |object, walker|
      unless walker.modify
        object.each { walker.visit(it) }
        next object
      end
      walker.update(object, object.to_a, hash_keys: !object.compare_by_identity?) do |target, results|
        results.each { walker.check_hash_key(it) } unless target.compare_by_identity?
        target.clear
        results.each { target.add(it) }
        target
      end
    end

    define(Hash, Abstract::Map) do |object, walker|
      unless walker.modify
        object.each do |key, value|
          walker.visit(key)
          walker.visit(value)
        end
        next(Hash === object ? super(object, walker) : object)
      end
      values = object.each.flat_map { |key, value| [key, value] }
      identity = Hash === object ? object.compare_by_identity? : object.compare_keys_by_identity?
      result = walker.update(object, values, hash_keys: !identity, key_stride: 2) do |target, results|
        results.each_slice(2) { |key, _| walker.check_hash_key(key) } unless identity
        target.clear
        results.each_slice(2) { |key, value| target[key] = value }
        target
      end
      Hash === object ? super(result, walker) : result
    end

    define(Abstract::ConcurrentMap) do |object, walker|
      values = object.each.flat_map { |key, value| [key, value] }
      walker.update(object, values, hash_keys: !object.compare_keys_by_identity?, key_stride: 2) do |target, results|
        if !target.compare_keys_by_identity? && values.each_slice(2).any? { |key, _| walker.changed?(key) }
          results.each_slice(2) { |key, _| walker.check_hash_key(key) }
          target.clear
          results.each_slice(2) { |key, value| target[key] = value }
          next target
        end
        entries = []
        values.each_slice(2).with_index do |(key, value), index|
          new_key, result = results[index * 2, 2]
          walker.check_hash_key(new_key) unless target.compare_keys_by_identity?
          if !key.equal?(new_key)
            entries << [key, new_key, result]
          elsif !value.equal?(result)
            until target.compare_and_set(key, value, result)
              value = target[key]
              result = walker.visit(value)
            end
          end
        end
        entries.each { |key, _, _| target.delete(key) }
        entries.each { |_, key, value| target[key] = value } # rubocop:disable Style/CombinableLoops
        target
      end
    end

    define(Abstract::LeaseMap) do |object, walker|
      object.auto_lease do
        values = object.keys.flat_map { |key| [key, object[key]] }
        walker.update(object, values, hash_keys: !object.compare_keys_by_identity?, key_stride: 2) do |target, results|
          target.auto_lease do
            results.each_slice(2) { |key, _| walker.check_hash_key(key) } unless target.compare_keys_by_identity?
            values.each_slice(2).with_index do |(key, _), index|
              target.delete(key) unless key.equal?(results[index * 2])
            end
            results.each_slice(2) { |key, value| target[key] = value }
          end
          target
        end
      end
    end

    define(Abstract::Lease) do |object, walker|
      value = object.checkout
      checked_out = true
      walker.update(object, [value]) do |target, results|
        unless checked_out
          value = target.checkout
          checked_out = true
        end
        begin
          target.checkin(results.first)
          checked_out = false
          target
        ensure
          if checked_out
            target.checkin(value)
            checked_out = false
          end
        end
      end
    ensure
      object.checkin(value) if checked_out
      checked_out = false
    end

    define(Proc) do |object, walker|
      if Internal.rebindable?(object)
        object = walker.update(object, [object.binding.receiver]) do |target, results|
          Farce.rebind(target, self: results.first)
        end
      end
      super(object, walker)
    end

    define(Data) do |object, walker|
      walker.rebuild_data(object)
    end
  end
end
