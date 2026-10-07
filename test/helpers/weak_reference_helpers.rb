# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Helpers
  module WeakReferenceHelpers
    def collected_reference(klass, freeze_value: false)
      # A disposable stack avoids stale references during conservative GC scans.
      reference = Thread.new do
        value = Object.new
        value.freeze if freeze_value
        klass.new(value)
      end.value

      50.times do
        2_000.times { Object.new }
        RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
        return reference unless reference_alive?(reference)
        sleep 0.01
      end

      flunk "weak reference remained alive after repeated collections"
    end

    def reference_alive?(reference)
      reference.respond_to?(:weakref_alive?) ? reference.weakref_alive? : reference.alive?
    end
  end
end
