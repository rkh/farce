# frozen_string_literal: true

require_relative "gem_verifier"
require "rake_compiler_dock"

# A platform added to CROSS_PLATFORMS without a signature would be built but never checked.
mismatch = (GemVerifier.targets | CROSS_PLATFORMS) - (GemVerifier.targets & CROSS_PLATFORMS)
raise "GemVerifier and CROSS_PLATFORMS disagree about #{mismatch.join(", ")}" if mismatch.any?

namespace :gem do
  # The source gemspec is where both the version and the set of extensions come from.
  source_spec = -> { Gem::Specification.load("farce.gemspec") }
  ext_names   = -> { source_spec.call.extensions.map { File.basename(File.dirname(it)) } }
  abis        = -> { ENV.fetch("RUBY_CC_VERSION") { raise "RUBY_CC_VERSION is not set" }.split(":") }

  # JRuby builds a gem named for the platform it declares (java), not for the build target.
  gem_file = lambda do |platform|
    "pkg/farce-#{source_spec.call.version}#{"-#{GemVerifier.gem_platform(platform)}" if platform}.gem"
  end

  # Nothing about a wrong-architecture gem looks wrong until someone installs it, so check the
  # artifact itself rather than trusting that the build did what it was told.
  verify = lambda do |platform|
    file   = gem_file[platform]
    checks = GemVerifier.verify(file, platform:, abis: abis.call, names: ext_names.call)
    width  = checks.keys.map(&:length).max

    puts "verify #{File.basename(file)}", *checks.map { |label, detail| "  #{label.ljust(width)}  #{detail}  OK" }
  rescue GemVerifier::Error => e
    raise GemVerifier::Error, "#{File.basename(file)} #{e.message}"
  end

  gem_command = ->(gemspec) { "gem build #{gemspec} && mkdir -p pkg && mv farce-*.gem pkg/" }

  task prepare: :clobber do # rubocop:disable Rake/Desc
    mkdir_p("vendor/cache")
    sh "gem build farce.gemspec && mv farce-*.gem vendor/cache"
    sh "bundle cache --all-platforms"
    rm_f Dir.glob("vendor/cache/farce-*.gem")
  end

  desc "Build the pure-source gem (compiles at install time on CRuby)"
  task source: :prepare do
    sh gem_command["farce.gemspec"]
    verify[nil]
  end

  CROSS_PLATFORMS.each do |platform|
    desc "Build the precompiled gem for #{platform}"
    task platform => :prepare do
      # No `cross` here: it dereferences Rake::Task["native"], which rake-compiler never defines
      # when RAKE_EXTENSION_TASK_NO_NATIVE is set -- as rake-compiler-dock does.
      command = platform == "jruby" ?
        gem_command["farce-java.gemspec"] :
        "bundle install && bundle exec rake native:#{platform} gem"

      RakeCompilerDock.sh(command, platform:)
      verify[platform]
    end
  end

  namespace :verify do
    CROSS_PLATFORMS.each do |platform|
      desc "Verify the built gem for #{platform}"
      task(platform) { verify[platform] }
    end

    desc "Verify the built source gem"
    task(:source) { verify[nil] }
  end

  desc "Verify all built gems"
  task verify: [*CROSS_PLATFORMS.map { "verify:#{it}" }, "verify:source"]

  desc "Build all gems"
  task all: %i[source cross_platforms]
  multitask cross_platforms: CROSS_PLATFORMS
end
