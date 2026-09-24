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

    autoload :WeakMap,         "farce/engine/shared/unshared_weak_map"
    autoload :WeakKeyMap,      "farce/engine/shared/unshared_weak_map"
    autoload :WeakValueMap,    "farce/engine/shared/unshared_weak_map"
    autoload :LeaseWaiting,    "farce/engine/jruby/lease_waiting"
    autoload :LFUMap,          "farce/engine/jruby/bounded_map"
    autoload :LRUMap,          "farce/engine/jruby/bounded_map"
    autoload :ShareableLFUMap, "farce/engine/jruby/bounded_map"
    autoload :ShareableLRUMap, "farce/engine/jruby/bounded_map"
    autoload :StrictLFUMap,    "farce/engine/jruby/bounded_map"
    autoload :StrictLRUMap,    "farce/engine/jruby/bounded_map"

    java_import org.jruby.RubyProc
    java_import org.jruby.runtime.Block

    def native_ractors? = false

    def prepare_mutable_numeric(klass) = klass.include MutableNumericCopy

    # Fibers expose their backing thread through Thread.current.
    def storage_thread(thread) = JRuby.reference(thread).getFiberCurrentThread

    def rebind(proc, new_self, lambda)
      # Proc#dup shares its binding. Copy the frame before changing the receiver,
      # while retaining the dynamic scope that owns captured local variables.
      jproc    = ref(proc)
      block    = jproc.get_block.clone_block_and_frame
      self_ref = ref(new_self)
      binding  = block.get_binding

      binding.set_self(self_ref)
      binding.get_frame.set_self(self_ref)

      lambda = proc.lambda? if lambda.nil?
      type = lambda ? Block::Type::LAMBDA : Block::Type::PROC
      rebound = RubyProc.new_proc(jproc.get_runtime, jproc.get_type, block, type, nil, -1)
      jproc.copy_instance_variables_into(ref(rebound).get_instance_variables)
      rebound
    end

    private

    def ref(obj) = JRuby.reference(obj)
  end
end
