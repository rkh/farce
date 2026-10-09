# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

namespace :release do
  desc "Check that the release tag matches the gem version"
  task :validate do
    version = Gem::Specification.load("farce.gemspec").version.to_s
    tag = ENV.fetch("GITHUB_REF_NAME")
    raise "Release tag #{tag.inspect} does not match version #{version}" unless [version, "v#{version}"].include?(tag)
    raise "Releases require a pushed tag" unless ENV["GITHUB_REF_TYPE"] == "tag"
  end

  desc "Build and verify the source gem and all binary gems for release"
  task build: [:validate, "gem:all", "gem:verify"]
end

desc "Publish the verified source gem and all binary gems to RubyGems.org"
task release: ["release:validate", "gem:verify"] do
  version = Gem::Specification.load("farce.gemspec").version
  platforms = CROSS_PLATFORMS.map { GemVerifier.gem_platform(it) }
  expected = ["pkg/farce-#{version}.gem", *platforms.map { "pkg/farce-#{version}-#{it}.gem" }].sort
  actual = Dir["pkg/*.gem"]
  raise "Release artifacts do not match the source gem and all binary platforms" unless actual == expected

  expected.each { sh "gem", "push", "--host", "https://rubygems.org", it }
end
