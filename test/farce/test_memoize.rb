# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestMemoize < Test
    include Helpers::InternalTestHelpers

    class Value
      include Memoize[:value]

      attr_reader :calls

      def initialize(result = :ready)
        @result = result
        @calls = Counter.new
      end

      def value
        @calls.increment
        Thread.pass
        @result
      end
    end

    class ArrayValue
      attr_reader :calls

      def initialize = @calls = Counter.new

      def value
        @calls.increment
        []
      end
    end

    class FrozenArrayValue < ArrayValue
      def value = super.freeze
    end

    class ResultValue
      attr_reader :calls

      def initialize(result)
        @result = result
        @calls = Counter.new
      end

      def value
        @calls.increment
        Thread.pass
        @result
      end
    end

    class FlakyValue
      include Memoize[:value]

      attr_reader :calls

      def initialize = @calls = Counter.new

      def value
        raise "not ready" if @calls.increment == 1
        :ready
      end
    end

    def test_include_adds_the_memoize_class_method
      klass = Class.new(Value) do
        include Memoize

        memoize def another = Object.new.freeze
      end
      object = klass.new

      assert_same object.another, object.another
      refute_same object.another, klass.new.another
    end

    def test_memoizes_lazily_per_instance
      first = Value.new
      second = Value.new

      assert_equal 0, first.calls.value
      2.times { assert_equal :ready, first.value }
      assert_equal 1, first.calls.value
      assert_equal 0, second.calls.value
      assert_equal :ready, second.value
      assert_equal 1, second.calls.value
    end

    def test_caches_nil_and_false
      [nil, false].each do |result|
        object = Value.new(result)

        2.times { result.nil? ? assert_nil(object.value) : assert_same(result, object.value) }

        assert_equal 1, object.calls.value
      end
    end

    def test_can_compute_after_freezing
      object = Value.new.freeze

      assert_equal 0, object.calls.value
      2.times { assert_equal :ready, object.value }
      assert_equal 1, object.calls.value
    end

    def test_forwards_initializer_arguments_keywords_and_block
      klass = Class.new do
        include Memoize[:value]

        def initialize(first, last:, &block)
          @result = block.call(first, last)
        end

        def value = @result
      end

      object = klass.new(20, last: 22) { _1 + _2 }

      assert_equal 42, object.value
    end

    def test_memoized_methods_are_available_during_initialization
      klass = Class.new(ArrayValue) do
        include Memoize[:value]

        attr_reader :initial

        def initialize
          super
          @initial = value
          freeze
        end
      end
      object = klass.new

      assert_same object.initial, object.value
      assert_equal 1, object.calls.value
    end

    def test_retries_after_a_method_raises
      object = FlakyValue.new.freeze

      assert_raises(RuntimeError) { object.value }
      2.times { assert_equal :ready, object.value }
      assert_equal 2, object.calls.value
    end

    def test_computes_once_under_thread_contention
      object = Value.new.freeze
      workers = 8.times.map { Thread.new { object.value } }

      assert_equal [:ready], workers.map(&:value).uniq
      assert_equal 1, object.calls.value
    ensure
      workers&.each { it.kill.join }
    end

    def test_computes_once_across_ractors
      object = Ractor.make_shareable(Value.new)
      workers = 4.times.map { Ractor.new(object, &:value) }

      assert_equal [:ready], workers.map { ractor_value(it) }.uniq
      assert_equal 1, object.calls.value
    end

    def test_mixin_cache_normalizes_method_names_order_and_defaults
      mixin = Memoize[:first, :last]

      assert_same mixin, Memoize["last", :first, :first, scope: :global, mode: :smart, weak: false, visibility: :public]
      assert_equal %i[first last], mixin.memoized_methods
      assert_equal :global, mixin.scope
      assert_equal :smart, mixin.mode
      assert_equal :public, mixin.visibility
      refute_predicate mixin, :weak?
      refute_same mixin, Memoize[:first, :last, mode: :raise]
    end

    def test_mixin_subclasses_can_be_constructed
      mixin = Class.new(Memoize::Mixin).new([:value], scope: :global, mode: :smart, weak: false)
      object = Class.new(ArrayValue) { include mixin }.new

      assert_empty object.value
      assert_same object.value, object.value
    end

    def test_overlapping_memoization_declarations_use_independent_slots
      klass = Class.new(Value) do
        include Memoize

        memoize :value, :another
        def another = :other
      end
      object = klass.new

      2.times { assert_equal :ready, object.value }
      assert_equal :other, object.another
      assert_equal 1, object.calls.value
    end

    def test_reuses_mixins_from_another_ractor
      mixin = Memoize[:value]
      worker = Ractor.new { Memoize[:value] }

      assert_same mixin, ractor_value(worker)
    end

    def test_preserves_inferred_visibility
      klass = Class.new do
        include Memoize

        def public_value = :public
        protected def protected_value = :protected
        private def private_value = :private

        memoize :public_value, :protected_value, :private_value
      end

      assert klass.public_method_defined?(:public_value)
      assert klass.protected_method_defined?(:protected_value)
      assert klass.private_method_defined?(:private_value)
    end

    def test_explicit_visibility_and_declaration_before_definition
      klass = Class.new do
        include Memoize

        memoize :value, visibility: :private
        def value = 42
      end

      assert klass.private_method_defined?(:value)
      assert_equal 42, klass.new.send(:value)
    end

    def test_warns_about_parameters_and_can_suppress_warning
      klass = Class.new do
        extend Memoize

        def value(optional = nil) = optional
      end

      _, warning = capture_io { klass.memoize :value }

      assert_match(/#value expects parameters/, warning)
      assert_silent { klass.memoize :value, warn: false }
    end

    def test_supports_predicate_and_bang_methods_without_ivar_collisions
      klass = Class.new do
        include Memoize[:ready, :ready?, :ready!]

        def ready = :plain
        def ready? = true
        def ready! = :bang
      end
      object = klass.new.freeze

      assert_equal :plain, object.ready
      assert_predicate object, :ready?
      assert_equal :bang, object.ready!
    end

    def test_rejects_unsuitable_method_names
      [:initialize, :"value=", :"a; raise", :@value].each do |name|
        assert_raises(ArgumentError) { Memoize[name] }
      end
    end

    def test_rejects_invalid_scope_mode_and_visibility_at_declaration
      assert_raises(ArgumentError) { Memoize[:value, scope: :unknown] }
      assert_raises(ArgumentError) { Memoize[:value, mode: :unknown] }
      assert_raises(ArgumentError) { Memoize[:value, visibility: :unknown] }
    end

    def test_applies_global_transfer_mode
      object = Class.new(ArrayValue) { include Memoize[:value, mode: :make_shareable] }.new.freeze

      assert_empty object.value
      assert_equal Internal.native_ractors?, object.value.frozen?
      assert_equal 1, object.calls.value
    end

    def test_strict_mode_caches_shareable_results_including_nil_and_false
      [false, true].each do |weak|
        klass = Class.new(ResultValue) { include Memoize[:value, mode: :strict, weak:] }

        [nil, false, [].freeze, Envelope.new(:payload)].each do |result|
          object = klass.new(result).freeze

          2.times { result.nil? ? assert_nil(object.value) : assert_same(result, object.value) }

          assert_equal 1, object.calls.value
        end
      end
    end

    def test_strict_mode_rejects_unshareable_results_without_caching_or_freezing_them
      [false, true].each do |weak|
        klass = Class.new(ResultValue) { include Memoize[:value, mode: :strict, weak:] }
        result = Internal.native_ractors? ? Object.new : Unshared::Atom.new
        object = klass.new(result).freeze

        2.times { assert_raises(Ractor::IsolationError) { object.value } }

        refute_predicate result, :frozen?
        assert_equal 2, object.calls.value
      end
    end

    def test_strict_mode_computes_once_across_ractors
      [false, true].each do |weak|
        klass = Class.new(ResultValue) { include Memoize[:value, mode: :strict, weak:] }
        result = Object.new.freeze
        object = Ractor.make_shareable(klass.new(result))
        workers = 4.times.map { Ractor.new(object, &:value) }

        workers.each { assert_same result, ractor_value(it) }

        assert_equal 1, object.calls.value
      end
    end

    def test_global_copy_mode_caches_a_result_per_ractor
      return unless Internal.native_ractors?

      klass = Class.new(ArrayValue) { include Memoize[:value, mode: :copy] }
      object = Ractor.make_shareable(klass.new)
      object.value << :parent
      worker = Ractor.new(object) do |value|
        first = value.value
        first << :child
        [first.equal?(value.value), first]
      end

      assert_equal [true, [:child]], ractor_value(worker)
      assert_equal [:parent], object.value
      assert_equal 1, object.calls.value
    end

    def test_unshared_scope_keeps_original_values
      object = Class.new(ArrayValue) { include Memoize[:value, scope: :unshared] }.new.freeze
      first = object.value
      first << :item

      assert_same first, object.value
      assert_equal [:item], object.value
      assert_equal 1, object.calls.value
    end

    def test_all_local_scopes_accept_options_and_ignore_mode
      SCOPES.each do |scope|
        mixin = Memoize[:value, scope: scope, mode: :unknown]
        object = Class.new(ArrayValue) { include mixin }.new.freeze

        assert_same mixin, Memoize[:value, scope: scope]
        assert_equal scope, mixin.scope
        assert_nil mixin.mode
        assert_same object.value, object.value
        assert_equal 1, object.calls.value
      end
    end

    def test_fiber_scope_has_independent_caches
      object = Class.new(ArrayValue) { include Memoize[:value, scope: :fiber] }.new.freeze
      parent = object.value
      child = Fiber.new { [object.value, object.value] }.resume

      assert_same child.first, child.last
      refute_same parent, child.first
      assert_equal 2, object.calls.value
    end

    def test_thread_scope_is_shared_by_fibers_but_not_threads
      object = Class.new(ArrayValue) { include Memoize[:value, scope: :thread] }.new.freeze
      parent = object.value

      assert_same parent, Fiber.new { object.value }.resume
      refute_same parent, Thread.new { object.value }.value
      assert_equal 2, object.calls.value
    end

    def test_thread_group_scope_shares_values_within_each_group
      object = Class.new(ArrayValue) { include Memoize[:value, scope: :thread_group] }.new.freeze
      parent = object.value
      group = ThreadGroup.new
      inherited, child, nested = Thread.new do
        inherited = object.value
        group.add(Thread.current)
        [inherited, object.value, Thread.new { object.value }.value]
      end.value

      assert_same parent, inherited
      refute_same parent, child
      assert_same child, nested
      assert_equal 2, object.calls.value
    end

    def test_fiber_storage_inherits_values_and_accepts_independent_storage
      object = Class.new(ArrayValue) { include Memoize[:value, scope: :fiber_storage] }.new.freeze
      parent = object.value

      assert_same parent, Fiber.new { object.value }.resume
      refute_same parent, Fiber.new(storage: {}) { object.value }.resume
      assert_same parent, object.value
      assert_equal 2, object.calls.value
    end

    def test_ractor_scope_has_independent_caches
      object = Ractor.make_shareable(Class.new(ArrayValue) { include Memoize[:value, scope: :ractor] }.new)
      object.value << :parent
      worker = Ractor.new(object) do |value|
        first = value.value
        first << :child
        [first.equal?(value.value), first]
      end

      assert_equal [true, [:child]], ractor_value(worker)
      assert_equal [:parent], object.value
      assert_equal 2, object.calls.value
    end

    def test_weak_global_scope_defaults_to_raise_and_rejects_unsupported_modes
      mixin = Memoize[:value, weak: true]
      object = Class.new(Value) { include mixin }.new

      assert_predicate mixin, :weak?
      assert_equal :raise, mixin.mode
      assert_equal :ready, object.value
      assert_raises(ArgumentError) { Memoize[:value, weak: true, mode: :copy] }
    end

    def test_weak_values_are_retained_only_while_referenced
      [{ mode: :make_shareable }, { mode: :strict }, { scope: :unshared }, { scope: :ractor }].each do |options|
        mixin = Memoize[:value, weak: true, **options]
        value_class = options[:mode] == :strict ? FrozenArrayValue : ArrayValue
        object = Class.new(value_class) { include mixin }.new.freeze
        reference, reused = Thread.new do
          value = object.value
          [WeakValue.new(value), value.equal?(object.value)]
        end.value

        assert reused
        assert_equal 1, object.calls.value
        # Drop temporary values from the test's stack before requesting collection.
        50.times do
          2_000.times { Object.new }
          RUBY_ENGINE == "jruby" ? java.lang.System.gc : GC.start
          break unless reference.alive?
          sleep 0.01
        end

        refute_predicate reference, :alive?
        assert_empty object.value
        assert_equal 2, object.calls.value
      end
    end

    def test_marshal_round_trip_preserves_unresolved_and_cached_values
      [nil, false, :ready].each do |result|
        original = Value.new(result)
        unresolved = Marshal.load(Marshal.dump(original))

        assert_equal 0, unresolved.calls.value
        result.nil? ? assert_nil(unresolved.value) : assert_same(result, unresolved.value)
        result.nil? ? assert_nil(original.value) : assert_same(result, original.value)
        restored = Marshal.load(Marshal.dump(original))

        2.times { result.nil? ? assert_nil(restored.value) : assert_same(result, restored.value) }

        assert_equal 1, restored.calls.value
      end
    end
  end
end
