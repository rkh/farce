# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "digest"
require "rake/extensiontask"
require_relative "../ext/ext_helper"
require_relative "liburing"

class ExtensionTask < Rake::ExtensionTask
  class NativeConfigurationCheck < Rake::Task
    # Check on every invocation without making unchanged file prerequisites stale.
    def timestamp = Rake::EARLY
  end

  private_constant :NativeConfigurationCheck

  private

  # rake-compiler hooks up `file lib/…/<ext>.<dlext> => copy:<ext>:<host platform>:<host version>`
  # whenever a build target matches the host, and it does so even when native builds are turned
  # off. Inside rake-compiler-dock (which sets RAKE_EXTENSION_TASK_NO_NATIVE) that hook makes
  # every precompiled gem depend on a host-native build of the extension: it writes Makefiles
  # holding container-specific header paths into tmp/, and host binaries into lib/. Both are
  # shared between platforms through the bind mount, so the next platform picks them up and its
  # build breaks. Honour no_native fully instead: skip the host tasks, leaving cross builds to
  # assemble the gem from tmp/<platform>/stage only.
  def define_compile_tasks(for_platform = nil, ruby_ver = RUBY_VERSION)
    return if for_platform.nil? && no_native
    super
    define_native_configuration_check(ruby_ver) if for_platform.nil?
  end

  def define_native_configuration_check(ruby_ver)
    tmp_path = "#{@tmp_dir}/#{platform}/#{@name}/#{ruby_ver}"
    stamp = "#{tmp_path}/ruby-config.stamp"
    makefile = "#{tmp_path}/Makefile"
    native_binary = "#{tmp_path}/#{binary(platform)}"

    check = NativeConfigurationCheck.define_task("#{stamp}:check" => tmp_path) do
      fingerprint = native_configuration_fingerprint
      next if File.file?(stamp) && File.binread(stamp) == fingerprint

      # Dev Ruby updates can keep RUBY_VERSION while replacing headers and configuration.
      # Remove cached outputs as their timestamps may be newer than the new Ruby's files.
      rm_f [makefile, native_binary, *Dir.glob("#{tmp_path}/**/*.{o,obj}")]
      File.binwrite(stamp, fingerprint)
    end

    file stamp => check.name
    file makefile => stamp
  end

  def native_configuration_fingerprint(revision: RUBY_REVISION, config: RbConfig::CONFIG,
                                       paths: $LOADED_FEATURES.grep(%r{(?:\A|[/\\])(?:rbconfig|mkmf)\.rb\z}))
    Digest::SHA256.hexdigest(Marshal.dump([revision, config.sort, paths.sort]))
  end

  # Build with the same target configuration that extconf will use.
  def make_makefile_cmd(root_path, tmp_path, extconf, cross_platform)
    command = super
    return command unless @name == "farce" && cross_platform&.include?("-linux-")

    prefix = File.expand_path("tmp/#{cross_platform}/liburing-#{Liburing::VERSION}", root_path)
    sh Gem.ruby, File.join(root_path, "rakelib/liburing.rb"), File.expand_path("#{tmp_path}/fake.rb", root_path), prefix
    command + ["--with-uring-dir=#{prefix}", "--enable-uring-static"]
  end

  # Version with custom lib_dir adjustment
  def define_cross_platform_tasks(for_platform)
    versions = ENV["RUBY_CC_VERSION"]&.split(":") || [RUBY_VERSION]
    lib_dir  = @lib_dir

    versions.each do |version|
      engine   = for_platform == "java" ? "jruby" : RUBY_ENGINE
      @lib_dir = ExtHelper.ext_path(engine:, version:, lib: true)
      define_cross_platform_tasks_with_version(for_platform, version)
    ensure
      @lib_dir = lib_dir
    end
  end
end
