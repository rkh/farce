# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "../setup"
require "tmpdir"

module Farce
  class TestRequireHooks < Test
    def test_alias_method_chain_after_farce
      assert_alias_method_chain(autoload: true)
    end

    def test_alias_method_chain_after_farce_with_integrations_disabled
      assert_alias_method_chain(autoload: false)
    end

    def test_alias_method_chain_without_farce
      assert_alias_method_chain(load_farce: false)
    end

    def test_bundler_require_with_later_alias_method_chain
      assert_bundler_require(autoload: true)
    end

    def test_bundler_require_with_later_alias_method_chain_and_integrations_disabled
      assert_bundler_require(autoload: false)
    end

    def test_bundler_require_with_alias_method_chain_without_farce
      assert_bundler_require(load_farce: false)
    end

    def test_alias_method_chain_preserves_secondary_ractor_requires
      return unless Helpers::Internal.native_ractors?

      with_require_hook_fixture do |directory|
        feature = File.join(directory, "secondary_ractor_probe.rb")
        File.write(feature, "module FarceSecondaryRequireProbe; VALUE = 42; end\n")

        [true, false].each do |autoload|
          assert_require_process(<<~RUBY, autoload:)
            require "farce"
            require #{File.join(directory, "require_hook_fixture.rb").dump}
            worker = ::Ractor.new(#{feature.dump}) do |path|
              first = require(path)
              [first, FarceSecondaryRequireProbe::VALUE, require(path)]
            end
            result = worker.respond_to?(:value) ? worker.value : worker.take
            raise "secondary Ractor require changed" unless result == [true, 42, false]
            puts "ok"
          RUBY
        end
      end
    end

    private

    def assert_alias_method_chain(autoload: true, load_farce: true)
      with_require_hook_fixture do |directory|
        assert_require_process(<<~RUBY, autoload:)
          #{'require "farce"' if load_farce}
          require #{File.join(directory, "require_hook_fixture.rb").dump}
          puts "ok"
        RUBY
      end
    end

    def assert_bundler_require(autoload: true, load_farce: true)
      with_require_hook_fixture do |directory|
        # Load Farce first, then a local gem that wraps require during startup.
        # All dependencies are local, so this needs no installation or network.
        gemfile = File.join(directory, "Gemfile")
        root = File.expand_path("../..", __dir__)
        File.write(gemfile, <<~GEMFILE)
          #{"gem \"farce\", path: #{root.dump}" if load_farce}
          gem "require_hook_fixture", path: #{directory.dump}
        GEMFILE

        assert_require_process(<<~RUBY, autoload:)
          require "bundler"
          ENV["BUNDLE_GEMFILE"] = #{gemfile.dump}
          Bundler.reset!
          Bundler.require
          puts "ok"
        RUBY
      end
    end

    def assert_require_process(source, autoload:)
      env = { "FARCE_AUTOLOAD_INTEGRATIONS" => autoload.to_s, "RUBYOPT" => nil }
      # A broken require can also break lazy loading in Ruby's error formatter.
      env["RUBYOPT"] = "--disable-error_highlight --disable-did_you_mean" if RUBY_ENGINE == "ruby"
      output, error, status = Bundler.with_unbundled_env do
        ruby_subprocess(source, env:, timeout: 60, coverage: false)
      end

      assert_predicate status, :success?, "#{output}\n#{error}"
      assert_equal "ok", output.lines.last&.strip
    end

    def with_require_hook_fixture
      Dir.mktmpdir("farce-require-hook-") do |directory|
        File.write(File.join(directory, "require_hook_fixture.gemspec"), <<~RUBY)
          Gem::Specification.new("require_hook_fixture", "1.0.0") do |spec|
            spec.summary = "Alias method chain regression fixture"
            spec.authors = ["Farce tests"]
            spec.files = ["require_hook_fixture.rb", "require_hook_probe.rb"]
            spec.require_paths = ["."]
          end
        RUBY
        File.write(File.join(directory, "require_hook_probe.rb"), "$farce_require_hook_probe_loaded = true\n")
        File.write(File.join(directory, "require_hook_fixture.rb"), <<~RUBY)
          module Kernel
            alias require_without_farce_test_hook require

            def require(path)
              require_without_farce_test_hook(path)
            end

            private :require, :require_without_farce_test_hook
          end

          probe = File.expand_path("require_hook_probe.rb", __dir__)
          raise "first require should return true" unless require(probe)
          raise "feature was not loaded" unless $farce_require_hook_probe_loaded
          raise "second require should return false" if require(probe)
          raise "require became public" if Object.public_method_defined?(:require)
        RUBY
        yield directory
      end
    end
  end
end
