# frozen_string_literal: true

require_relative "java_extension"

namespace :java do
  desc "Build JRuby scheduler bindings (set JRUBY_JAR; not needed on gem installation)"
  task(:scheduler) { JavaExtension.build_scheduler }

  desc "Build the portable Java extension (requires a JDK; never runs during gem installation)"
  task :compile do
    JavaExtension.build
  end
end

# CRuby development does not need a JDK. JVM development and gem releases do.
task compile: "java:compile"   if RUBY_ENGINE == "jruby" || (RUBY_ENGINE == "truffleruby" && !TruffleRuby.native?)
task compile: "java:scheduler" if RUBY_ENGINE == "jruby" # rubocop:disable Rake/DuplicateTask
