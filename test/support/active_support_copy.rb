# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "farce/integrations/active_support"

module Farce
  class ActiveSupportCopyTests < Test
    def test_copyable_objects
      target = Object.new
      objects = [Map.new, Set.new, Vector.new, Config.new, ModeManager.new,
                 Lazy.new { nil }, Local::Lazy.new { nil }, WeakValue.new(target), WeakRef.new(target),
                 Reference.new(Atom.new(nil))]

      objects.each { |object| assert_predicate object, :duplicable? }
    end

    def test_noncopyable_objects
      objects = [Queue.new, LeaseMap.new { {} }, Unshared::LeaseMap.new { {} }, Local::LeaseMap.new { {} },
                 Envelope::Move.new([]), Lease.new { Object.new }, Resolv::DNS.new]

      objects.each { |object| refute_predicate object, :duplicable? }
      scheduler = Object.new.extend(Internal::SchedulerLifecycle)

      refute_predicate scheduler, :duplicable?
    ensure
      objects&.last&.close
    end
  end
end
