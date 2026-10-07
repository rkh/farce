# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby" && RUBY_VERSION >= "4" && !Gem.win_platform?

require_relative "../setup"
require "ractor/sharing"

module Farce
  class TestRactorSharing < Test
    class ActiveBox < ::Ractor::ActiveObject
      sync attr_reader :value

      def initialize(value)
        super()
        @value = value
      end
    end

    def test_dependency_activates_integration
      assert_includes Integrations.load_active, :ractor_sharing
      assert_includes ::Ractor::TVar.ancestors, Internal::Noncopyable
    end

    def test_walker_traverses_and_updates_variables
      [::Ractor::TVar.new([1]), ::Ractor::LockVar.new([1])].each do |variable|
        assert_equal [1, variable.value, variable], Walker.each(variable).to_a
        assert_same variable, increment(variable, copy: true)
        assert_equal [2], variable.value
      end
    end

    def test_walker_traverses_and_updates_hashes
      [::Ractor::LockHash, ::Ractor::KeyLockHash].each do |klass|
        map = klass.new({ 1 => 10, 2 => 20 })
        visited = Walker.each(map).to_a

        assert_same map, visited.last
        assert_equal [1, 2, 10, 20], visited[0...-1].sort
        assert_same map, increment(map, copy: true)
        assert_equal({ 2 => 11, 3 => 21 }, map.to_h)
      end
    end

    def test_enfarce_converts_lock_hashes_in_each_namespace
      [::Ractor::LockHash, ::Ractor::KeyLockHash].product([Farce, Local, Strict, Unsafe, Unshared]).each do |klass, ns|
        source = klass.new({ values: [1, { name: :ruby }].freeze })
        result = ns.enfarce(source, freeze: false)

        assert_instance_of ns::Map, result
        assert_instance_of ns::Vector, result[:values]
        assert_instance_of ns::Map, result[:values][1]
        assert_equal :ruby, result[:values][1][:name]
        assert_equal [1, { name: :ruby }], source[:values]
      end
    end

    def test_active_objects_stop_at_owner_ractor_boundary
      map = ::Ractor::ActorHash.new(value: [1])
      object = ActiveBox.new([1])

      assert_equal [map], Walker.each(map).to_a
      assert_equal [object], Walker.each(object).to_a
      assert_same map, Walker.modify(map, copy: true) { |_, walker| walker.traverse }
      assert_equal({ value: [1] }, map.to_h)
      assert_equal [1], object.value
    end

    private

    def increment(object, **)
      Walker.modify(object, **) do |value, walker|
        Integer === value ? value + 1 : walker.traverse
      end
    end
  end
end
