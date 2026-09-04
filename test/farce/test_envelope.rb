# frozen_string_literal: true

require_relative "../setup"
require "pp"

module Farce
  class TestEnvelope < Test
    include Helpers::InternalTestHelpers

    class Payload
      include Unshareable::Movable
      include Unshareable::Copyable

      attr_accessor :value

      def initialize(value)
        @value = value
      end

      def ==(other) = other.is_a?(self.class) && value == other.value

      def inspect = "#<Payload #{@value.inspect}>"
    end

    def test_selects_a_subclass_from_the_value_and_options
      assert_instance_of Envelope::Copy, Envelope.new(Payload.new(:copy))
      assert_instance_of Envelope::Move, Envelope.new(Payload.new(:move), move: true)
      assert_instance_of Envelope::Local, Envelope.new(Payload.new(:local), local: true)
      assert_instance_of Envelope::Local, Envelope.new(Payload.new(:local), move: true, local: true)
      assert_instance_of Envelope::Share, Envelope.new(:shared, move: true, local: true)
      assert_raises(ArgumentError) { Envelope.new(Payload.new(:value), unknown: true) }
    end

    def test_share_envelope
      value = "shared"
      envelope = Envelope.new(value)

      assert_instance_of Envelope::Share, envelope
      assert_envelope_is_shareable(envelope)
      assert_same value, envelope.value
      assert_same envelope, envelope.claim
      assert_same envelope, envelope.claim!
      assert_predicate envelope, :claimed?
      assert_predicate envelope, :owned?
      assert_nil envelope.auto_unwrap
    end

    def test_share_rejects_an_unshareable_value
      error = assert_raises(ArgumentError) { Envelope::Share.new(Payload.new(:value)) }

      assert_equal "value must be shareable", error.message
    end

    def test_copy_preserves_a_snapshot_and_reuses_it_in_one_ractor
      source = Payload.new(:original)
      envelope = Envelope::Copy.new(source)
      source.value = :changed

      assert_envelope_is_shareable(envelope)
      assert_same envelope, envelope.claim
      assert_same envelope, envelope.claim!
      assert_predicate envelope, :claimed?
      assert_predicate envelope, :owned?

      value = envelope.value

      refute_same source, value
      assert_equal :original, value.value
      assert_same value, envelope.value
    end

    def test_copy_produces_a_distinct_value_in_each_ractor
      envelope = Envelope::Copy.new(Payload.new(:value))
      local_value = envelope.value
      worker = Ractor.new(envelope) do |shared|
        first = shared.value
        second = shared.value
        [
          first.value,
          first.object_id,
          second.object_id,
          shared.claim.equal?(shared),
          shared.claimed?,
          shared.owned?
        ].freeze
      end

      value, first_id, second_id, claimed, claimed_predicate, owned = ractor_value(worker)

      assert_equal :value, value
      assert_equal first_id, second_id
      refute_equal local_value.object_id, first_id
      assert claimed
      assert claimed_predicate
      assert owned
    end

    def test_move_can_be_claimed_and_read_repeatedly_by_its_owner
      envelope = Envelope::Move.new(Payload.new(:value))

      assert_envelope_is_shareable(envelope)
      refute_predicate envelope, :claimed?
      refute_predicate envelope, :owned?
      assert_same envelope, envelope.claim
      assert_same envelope, envelope.claim!
      assert_predicate envelope, :claimed?
      assert_predicate envelope, :owned?

      value = envelope.value

      assert_equal :value, value.value
      assert_same value, envelope.value
    end

    def test_move_can_only_be_claimed_by_one_ractor
      envelope = Envelope::Move.new(Payload.new(:value))
      worker = Ractor.new(envelope) do |shared|
        claim = shared.claim
        first = shared.value
        second = shared.value
        [
          claim.equal?(shared),
          first.value,
          first.equal?(second),
          shared.claimed?,
          shared.owned?
        ].freeze
      end

      assert_equal [true, :value, true, true, true], ractor_value(worker)
      assert_predicate envelope, :claimed?
      refute_predicate envelope, :owned?
      assert_nil envelope.claim

      error = assert_raises(Envelope::AlreadyClaimed) { envelope.claim! }

      assert_equal "envelope has already been claimed by another Ractor", error.message
      assert_raises(Envelope::AlreadyClaimed) { envelope.value }
    end

    def test_vault_backed_envelopes_compare_values_without_claiming_them
      moved = Envelope::Move.new(Payload.new(:same))
      equal = Envelope::Copy.new(Payload.new(:same))
      other = Envelope::Copy.new(Payload.new(:other))

      assert moved.same_value?(equal)
      refute moved.same_value?(other)
      refute moved.same_value?(equal, identity: true)
      assert moved.same_value?(moved, identity: true)
      refute_predicate moved, :claimed?

      moved_string = Envelope::Move.new(+"same")

      assert moved_string.same_value?("same")
      refute_predicate moved_string, :claimed?
    end

    def test_concurrent_move_claims_have_one_winner
      envelope = Envelope::Move.new(Payload.new(:value))
      workers = 4.times.map do
        Ractor.new(envelope) { |shared| !shared.claim.nil? }
      end

      results = workers.map { |worker| ractor_value(worker) }

      assert_equal 1, results.count(true)
      assert_equal 3, results.count(false)
      assert_predicate envelope, :claimed?
      refute_predicate envelope, :owned?
    end

    def test_local_envelope_is_only_owned_by_its_creator
      value = Payload.new(:value)
      envelope = Envelope::Local.new(value)

      assert_envelope_is_shareable(envelope)
      assert_predicate envelope, :claimed?
      assert_predicate envelope, :owned?
      assert_same envelope, envelope.claim
      assert_same value, envelope.value
      assert_same value, envelope.value

      worker = Ractor.new(envelope) do |shared|
        error = begin
          shared.value
        rescue StandardError => e
          [e.class.name, e.message].freeze
        end
        [shared.claim.nil?, shared.claimed?, shared.owned?, error].freeze
      end

      assert_equal(
        [
          true,
          true,
          false,
          [
            "Farce::Envelope::AlreadyClaimed",
            "envelope has already been claimed by another Ractor"
          ]
        ],
        ractor_value(worker),
      )
    end

    def test_wraps_an_existing_envelope_as_a_shareable_value
      inner = Envelope::Copy.new(Payload.new(:value))
      outer = Envelope.new(inner, move: true)

      assert_instance_of Envelope::Share, outer
      assert_same inner, outer.value

      shared = Envelope.new(Envelope::Share.new(:shared), move: true, local: true)

      assert_instance_of Envelope::Share, shared
      assert_instance_of Envelope::Share, shared.value
      assert_equal :shared, shared.value.value
    end

    def test_inspect_and_pretty_print_reflect_ownership
      shared = Envelope.new(:value)

      assert_equal "#<Farce::Envelope::Share value=:value>", shared.inspect
      assert_equal "#<Farce::Envelope::Share value=:value>", shared.pretty_inspect.chomp

      moved = Envelope::Move.new(Payload.new(:value))

      assert_equal "#<Farce::Envelope::Move unclaimed>", moved.inspect
      assert_equal "#<Farce::Envelope::Move unclaimed>", moved.pretty_inspect.chomp

      worker = Ractor.new(moved) { |envelope| envelope.claim && :claimed }

      assert_equal :claimed, ractor_value(worker)
      assert_equal "#<Farce::Envelope::Move claimed>", moved.inspect
      assert_equal "#<Farce::Envelope::Move claimed>", moved.pretty_inspect.chomp
    end

    private

    def assert_envelope_is_shareable(envelope)
      assert_kind_of Abstract::Value, envelope
      assert_predicate envelope, :frozen?
      assert_predicate envelope, :ractor_shareable?
      assert Ractor.shareable?(envelope)
    end
  end
end
