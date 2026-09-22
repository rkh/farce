# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestActiveSupportBoundary < Test
    def test_loading_active_support_does_not_freeze_config
      output, error, status = ruby_subprocess(<<~RUBY)
        require "farce"
        raise "config is already frozen" if Farce.config.frozen?

        require "farce/integrations/active_support"
        raise "loading ActiveSupport froze config" if Farce.config.frozen?
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end

    def test_blank_extensions_are_not_defined_by_core
      [Atom, Abstract::Atom, Abstract::Value, Envelope].each do |owner|
        refute_includes owner.public_instance_methods(false), :blank?, owner.name
      end
      refute Internal::Vault.method_defined?(:is_blank?)
      return unless Internal.native_ractors?

      refute Internal::Vault::Manager.method_defined?(:is_blank)
    end

    def test_active_support_methods_are_not_defined_by_core
      owners = [Config, WeakValue, WeakRef, Reference, Abstract::Queue, Abstract::Set,
                Abstract::LeaseMap, Abstract::DuplicableMap, Internal::Copyable,
                Internal::Noncopyable, Internal::SchedulerLifecycle]

      owners.each do |owner|
        refute_includes owner.public_instance_methods(false), :duplicable?, owner.name
      end
      [Map, Local::Map, LRUMap, LeaseMap].each do |type|
        refute type.method_defined?(:with_indifferent_access), type.name
        refute type.private_method_defined?(:indifferent_access_options), type.name
        refute type.private_method_defined?(:build_indifferent_access), type.name
      end
    end
  end
end
