# frozen_string_literal: true

require "rake/extensiontask"
require_relative "../ext/ext_helper"

class ExtensionTask < Rake::ExtensionTask
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
    super unless for_platform.nil? && no_native
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
