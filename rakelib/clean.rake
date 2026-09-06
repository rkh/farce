# frozen_string_literal: true

CLEAN.include(".yardoc", "**/*.log", "ext/*/{Makefile,*.bundle,*.bundle.dSYM}", "tmp")
CLOBBER.include("lib/**/*.{bundle,dylib,so,jar}", "coverage", "pkg", "yardoc")

task :clean do # rubocop:disable Rake/Desc
  Dir["pkg/*/README.md"].each { rm_rf File.dirname(it) }
end

task :clobber do # rubocop:disable Rake/Desc
  # delete empty directories after clobbering files
  Dir.glob("lib/**/*").each do |dir|
    next unless File.directory?(dir)
    rmdir(dir) if Dir.empty?(dir)
  end
end
