# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class ActiveSupportBlankTests < Test
    # Start the vault before the integration installs its command.
    EXISTING_ENVELOPE = Envelope::Move.new([])
  end
end

require "farce/integrations/active_support"

module Farce
  class ActiveSupportBlankTests < Test
    include Helpers::InternalTestHelpers

    class CustomBlank
      def blank? = true
    end

    class FailingBlank
      def blank? = raise(ArgumentError, "blank failure")
    end

    class ClaimDuringLookup < Envelope::Move
      protected

      def comparison_vault
        # Reproduce another thread in this Ractor retrieving between the ownership check and lookup.
        Thread.new { value }.value
        super
      end
    end

    def test_nil_atom_is_blank
      atom = Atom.new

      assert_predicate atom, :blank?
      refute_predicate atom, :present?
      assert_nil atom.presence
    end

    def test_atom_stored_nil_is_blank
      atom = Atom.new(:present)
      atom.store(nil)

      assert_predicate atom, :blank?
    end

    def test_atoms_match_active_support_value_semantics
      [Atom, Strict::Atom, Local::Atom, Strict::WeakAtom, Local::WeakAtom].each do |type|
        [false, true, 0, :value, "", " \t\n", "text", [].freeze, [nil].freeze, {}.freeze].each do |value|
          atom = type.new(value)

          assert_equal value.blank?, atom.blank?, "#{type}: #{value.inspect}"
          assert_equal value.present?, atom.present?, "#{type}: #{value.inspect}"
        end
      end
    end

    def test_other_atoms_handle_nil
      [Strict::Atom, Local::Atom, Strict::WeakAtom, Local::WeakAtom].each do |type|
        assert_predicate type.new(nil), :blank?
      end
    end

    def test_local_atom_uses_current_scope
      atom = Local::Atom.new("", scope: :fiber)
      atom.store("present")

      refute_predicate atom, :blank?
      assert Fiber.new { atom.blank? }.resume
    end

    def test_blank_move_atom_does_not_claim_its_value
      [[], [1]].each do |value|
        expected = value.empty?
        atom = Atom.new(value, mode: :move)
        envelope = atom.instance_variable_get(:@atom).value

        assert_equal expected, atom.blank?
        refute_predicate envelope, :claimed? if Envelope === envelope

        assert_equal expected, atom.value.empty?
      end
    end

    def test_move_envelope_is_inspected_without_claiming
      [[], [1]].each do |value|
        expected = value.empty?
        envelope = Envelope::Move.new(value)

        assert_equal expected, envelope.blank?
        assert_equal expected, envelope.blank?
        refute_predicate envelope, :claimed?
        assert_equal expected, envelope.value.empty?
      end
    end

    def test_vault_started_before_integration_accepts_blank_command
      assert_predicate EXISTING_ENVELOPE, :blank?
      refute_predicate EXISTING_ENVELOPE, :claimed?
    end

    def test_reading_from_another_ractor_does_not_claim
      envelope = Envelope::Move.new([1])
      result = ractor_value(Ractor.new(envelope) { |entry| [entry.blank?, entry.claimed?].freeze })

      assert_equal [false, false], result
      refute_predicate envelope, :claimed?
      assert_equal [1], envelope.value
    end

    def test_inaccessible_envelopes_are_blank
      moved = Envelope::Move.new([1])
      ractor_value(Ractor.new(moved) { |entry| entry.value.size })
      local = Envelope::Local.new([1])

      assert_predicate moved, :blank?
      refute_predicate moved, :owned?
      result = ractor_value(Ractor.new(local) { |entry| [entry.blank?, entry.owned?].freeze })

      assert_equal [true, false], result
      refute_predicate local, :blank?
    end

    def test_owned_envelopes_observe_mutations
      [Envelope::Copy, Envelope::Move, Envelope::Local].each do |type|
        envelope = type.new([1])
        envelope.value.clear

        assert_predicate envelope, :blank?
        envelope.value << 2

        refute_predicate envelope, :blank?
      end
    end

    def test_share_envelopes_delegate_blank
      [nil, false, true, "", " ", "present"].each do |value|
        assert_equal value.blank?, Envelope::Share.new(value).blank?
      end
    end

    def test_claim_in_current_ractor_between_check_and_lookup
      envelope = ClaimDuringLookup.new([1])
      observed = envelope.blank?

      assert_predicate envelope, :owned?
      assert_equal [1], envelope.value
      refute observed, "the nonblank value stays accessible in this Ractor throughout the operation"
    end

    def test_custom_blank_and_errors_execute_without_claiming
      custom = Envelope::Move.new(CustomBlank.new)
      failing = Envelope::Move.new(FailingBlank.new)

      assert_predicate custom, :blank?
      refute_predicate custom, :claimed?
      error = assert_raises(ArgumentError) { failing.blank? }

      assert_equal "blank failure", error.message
      refute_predicate failing, :claimed?
      assert_predicate Envelope::Move.new([]), :blank?
    end

    def test_value_wrappers_delegate_blank
      assert_predicate Flag.new(false), :blank?
      refute_predicate Flag.new(true), :blank?
      refute_predicate Counter.new(0), :blank?
      assert_predicate Lazy.new { nil }, :blank?
      refute_predicate Lazy.new { :value }, :blank?
    end

    def test_collections_keep_their_empty_based_semantics
      [Map.new, Set.new, Vector.new, Queue.new].each do |collection|
        assert_predicate collection, :blank?
      end
      queue = Queue.new
      queue.push(nil)

      [Map.new({ key: nil }), Set.new([nil]), Vector.new([nil]), queue].each do |collection|
        refute_predicate collection, :blank?
      end
    end
  end
end
