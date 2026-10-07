# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group WeakRef Integration
require "farce"   unless defined?(Farce::Walker)
require "weakref" unless defined?(WeakRef)

module Farce
  # Traverse the live referent. Collected references have no children.
  Walker.define(::WeakRef) do |object, walker|
    value = begin
      object.__getobj__
    rescue ::WeakRef::RefError
      next object
    end

    walker.update(object, [value]) do |target, results|
      # WeakRef has no setter, so replacement values need a new reference.
      target.class.new(results.first)
    end
  end

  Internal::Converter.define(::WeakRef, WeakRef) do
    def convert!(ref)
      @seen.fetch(ref) do
        begin
          value = ref.__getobj__
        rescue ::WeakRef::RefError
          next @seen[ref] = Farce::WeakRef::RECYCLED
        end
        converted = convert(value)
        # Return new values directly so they have a strong owner.
        @seen[ref] = converted.equal?(value) ? Farce::WeakRef.new(converted) : converted
      end
    end
  end
end
