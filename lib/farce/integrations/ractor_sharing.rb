# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group ractor-sharing Integration
require "farce"
require "ractor/tvar"
require "ractor/lockvar"
require "ractor/lockhash"
require "ractor/keylockhash"
require "ractor/active_object"
require "ractor/actor_hash"

module Farce
  [::Ractor::TVar, ::Ractor::LockVar, ::Ractor::LockHash, ::Ractor::KeyLockHash].each do |klass|
    klass.include(Internal::Noncopyable) unless klass < Internal::Noncopyable
  end

  Walker.define(::Ractor::TVar) do |object, walker|
    walker.update(object, [object.value]) do |target, results|
      ::Ractor.atomically { target.value = results.first unless target.value.equal?(results.first) }
      target
    end
  end

  Walker.define(::Ractor::LockVar) do |object, walker|
    walker.update(object, [object.value]) do |target, results|
      target.update { |value| value.equal?(results.first) ? value : results.first }
      target
    end
  end

  Walker.define(::Ractor::LockHash) do |object, walker|
    values = object.to_h.flat_map { |key, value| [key, value] }
    walker.update(object, values, hash_keys: true, key_stride: 2) do |target, results|
      results.each_slice(2) { |key, _| walker.check_hash_key(key) }
      target.synchronize do
        values.each_slice(2).with_index do |(key, _), index|
          key_result = results[index * 2]
          target.delete(key) unless key.equal?(key_result)
        end
        results.each_slice(2) { |key, value| target[key] = value }
      end
      target
    end
  end

  Walker.define(::Ractor::KeyLockHash) do |object, walker|
    values = object.to_h.flat_map { |key, value| [key, value] }
    walker.update(object, values, hash_keys: true, key_stride: 2) do |target, results|
      results.each_slice(2) { |key, _| walker.check_hash_key(key) }
      values.each_slice(2).with_index do |(key, _), index|
        key_result = results[index * 2]
        target.delete(key) unless key.equal?(key_result)
      end
      results.each_slice(2) { |key, value| target[key] = value }
      target
    end
  end

  Walker.define(::Ractor::ActiveObject::Proxy) do |object, _walker|
    object
  end
end
