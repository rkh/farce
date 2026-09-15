# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "jruby"
require "java"

require "farce/engine/shared"
require "farce/engine/jvm"

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    include Autoloads["#{__dir__}/jruby"]

    Lock = Mutex

    autoload :WeakMap,      "farce/engine/shared/unshared_weak_map"
    autoload :WeakKeyMap,   "farce/engine/shared/unshared_weak_map"
    autoload :WeakValueMap, "farce/engine/shared/unshared_weak_map"
    autoload :LeaseWaiting, "farce/engine/jruby/lease_waiting"

    java_import org.jruby.RubyProc
    java_import org.jruby.runtime.Block

    def native_ractors? = false

    # Fibers expose their backing thread through Thread.current.
    def storage_thread(thread) = JRuby.reference(thread).getFiberCurrentThread

    def rebind(proc, new_self, lambda)
      proc     = lambda.nil? ? proc.dup : change_lambda(proc, lambda)
      block    = ref(proc).get_block
      self_ref = ref(new_self)
      binding  = block.get_binding

      binding.set_self(self_ref)
      binding.get_frame.set_self(self_ref)

      proc
    end

    private

    def ref(obj) = JRuby.reference(obj)

    def change_lambda(proc, lambda)
      jproc = ref(proc)
      type  = lambda ? Block::Type::LAMBDA : Block::Type::PROC
      RubyProc.new_proc(jproc.get_runtime, jproc.get_block, type)
    end
  end
end
