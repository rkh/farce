# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group ActiveSupport Integration
require "farce/integrations/active_support"

module Farce
  class Config
    # @!macro active_support
    # @return [Boolean] true
    def duplicable? = true
  end

  class WeakValue
    # @!macro active_support
    # @return [Boolean] true
    def duplicable? = true
  end

  class WeakRef
    # @!macro active_support
    # @return [Boolean] true
    def duplicable? = true
  end

  class Reference
    # @!macro active_support
    # @return [Boolean] true
    def duplicable? = true
  end

  module Abstract
    class Queue
      # @!macro active_support
      # @return [Boolean] false
      def duplicable? = false
    end

    class Set
      # @!macro active_support
      # @return [Boolean] true
      def duplicable? = true
    end

    class LeaseMap
      # @!macro active_support
      # @return [Boolean] false
      def duplicable? = false
    end

    module DuplicableMap
      # @!macro active_support
      # @return [Boolean] true
      def duplicable? = true
    end
  end

  module Internal
    module Copyable
      # @!macro active_support
      # @return [Boolean] true
      def duplicable? = true
    end

    module Noncopyable
      # @!macro active_support
      # @return [Boolean] false
      def duplicable? = false
    end

    module SchedulerLifecycle
      # @!macro active_support
      # @return [Boolean] false
      def duplicable? = false
    end
  end
end
