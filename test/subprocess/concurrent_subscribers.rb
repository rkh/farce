# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/concurrent"

module Farce
  class ConcurrentSubscriberTests < Test
    include Helpers::ConcurrentSubscribers

    def concurrent_namespace = ::Concurrent
  end
end
