# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  module Internal
    # RubyNumeric's final Java clone methods return self. Invoke Object's copy
    # setup on a fresh Numeric to preserve Ruby's hooks and singleton methods.
    module MutableNumericCopy
      DUP_SETUP = org.jruby.RubyBasicObject.java_class.declared_method(
        "dupSetup", org.jruby.runtime.ThreadContext.java_class, org.jruby.RubyBasicObject.java_class,
      )

      CLONE_SETUP = org.jruby.RubyBasicObject.java_class.declared_method(
        "cloneSetup", org.jruby.runtime.ThreadContext.java_class, org.jruby.RubyBasicObject.java_class,
        org.jruby.runtime.builtin.IRubyObject.java_class,
      )

      DUP_SETUP.accessible = CLONE_SETUP.accessible = true

      private_constant :DUP_SETUP, :CLONE_SETUP

      def dup = copy_numeric(DUP_SETUP)

      def clone(freeze: nil)
        unless freeze.nil? || freeze.equal?(true) || freeze.equal?(false)
          raise ArgumentError, "unexpected value for freeze: #{freeze.class}"
        end
        copy_numeric(CLONE_SETUP, JRuby.reference(freeze))
      end

      private

      def copy_numeric(method, *)
        copy = JRuby.reference(self.class.allocate)
        method.invoke(JRuby.reference(self), JRuby.runtime.current_context, copy, *)
      rescue Java::JavaLangReflect::InvocationTargetException => e
        raise e.cause
      end
    end
  end
end
