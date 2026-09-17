# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    module JVMExtension
      jar = File.expand_path("farce.jar", __dir__)
      unless File.file?(jar)
        raise LoadError, "Farce's Java extension is missing; run rake java:compile in the source checkout"
      end

      if RUBY_ENGINE == "jruby"
        require "java"
        require jar
        BoundedMap    = Java::OrgFarce::BoundedMap
        PriorityKey   = Java::OrgFarce::PriorityKey
        PriorityQueue = Java::OrgFarce::PriorityQueue
        QueueFailure  = Java::OrgFarce::PriorityQueue::Failure
        QueueSignal   = Java::OrgFarce::QueueSignal
      else
        Java.add_to_classpath(jar)
        BoundedMap    = Java.type("org.farce.BoundedMap")
        PriorityKey   = Java.type("org.farce.PriorityKey")
        PriorityQueue = Java.type("org.farce.PriorityQueue")
        QueueFailure  = Java.type("org.farce.PriorityQueue$Failure")
        QueueSignal   = Java.type("org.farce.QueueSignal")
      end
    end
  end
end
