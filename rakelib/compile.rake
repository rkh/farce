# frozen_string_literal: true

require_relative "extension_task"
require "rake_compiler_dock"

gemspec = Gem::Specification.load("farce.gemspec")
RakeCompilerDock.set_ruby_cc_version(gemspec.required_ruby_version)

desc "Compile all extensions"
task :compile # dummy task for JRUBY

if RUBY_ENGINE != "jruby"
  extensions = RUBY_ENGINE == "ruby" ? "*" : "rbtree"
  Dir.glob("ext/#{extensions}/extconf.rb").each do |extconf|
    ext_dir  = File.dirname(extconf)
    ext_name = File.basename(ext_dir)

    ExtensionTask.new(ext_name, gemspec) do |ext|
      ext.ext_dir        = ext_dir
      ext.lib_dir        = ExtHelper.ext_path(lib: true)
      ext.cross_compile  = true
      ext.cross_platform = CROSS_PLATFORMS
    end
  end
end
