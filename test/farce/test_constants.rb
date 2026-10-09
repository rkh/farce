# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"

module Farce
  class TestConstants < Test
    def test_scopes
      assert_instance_of ::Set, Farce::SCOPES
      assert_predicate Farce::SCOPES, :frozen?
      assert Ractor.shareable?(Farce::SCOPES)
      refute Internal::Storage.const_defined?(:SCOPES, false)
    end

    def test_modes
      assert_instance_of ::Set, Farce::MODES
      assert_predicate Farce::MODES, :frozen?
      assert Ractor.shareable?(Farce::MODES)
      refute ModeManager.const_defined?(:MODES, false)
    end

    def test_constants_do_not_trigger_consumer_autoloads
      output, error, status = ruby_isolated(<<~RUBY, coverage: false, env: { "FARCE_AUTOLOAD_INTEGRATIONS" => "false" })
        require "farce"
        internal = Farce.const_get(:Internal, false)
        manager_autoload = Farce.autoload?(:ModeManager)
        storage_autoload = internal.autoload?(:Storage)
        raise "missing modes" unless Farce::MODES.include?(:copy)
        raise "missing scopes" unless Farce::SCOPES.include?(:thread)
        raise "ModeManager autoload triggered" unless Farce.autoload?(:ModeManager) == manager_autoload
        raise "Storage autoload triggered" unless internal.autoload?(:Storage) == storage_autoload
        Farce::MODES.each { |mode| Farce::Port.new(mode:) }
        Farce::SCOPES.each { |scope| Farce::Local::Atom.new(scope:) }
        wrapper = Farce::Proxy.const_get(:Wrapper, false)
        Farce::MODES.each do |mode|
          raise "missing proxy helper" unless wrapper.private_method_defined?("__\#{mode}__")
        end
      RUBY

      assert_predicate status, :success?, "#{output}\n#{error}"
    end
  end
end
