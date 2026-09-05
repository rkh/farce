# frozen_string_literal: true

require_relative "java_extension"

namespace :java do
  desc "Build the portable Java extension (requires a JDK; never runs during gem installation)"
  task :compile do
    JavaExtension.build
  end
end

# CRuby development does not need a JDK. JVM development and gem releases do.
task compile: "java:compile" if RUBY_ENGINE == "jruby" || (RUBY_ENGINE == "truffleruby" && !TruffleRuby.native?)
