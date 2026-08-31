# frozen_string_literal: true

require_relative "lib/farce/version"
require_relative "ext/ext_helper"

github = "https://github.com/rkh/farce"

Gem::Specification.new("farce", Farce::VERSION) do |spec|
  spec.authors       = ["Konstantin Haase"]
  spec.email         = ["konstantin.mailinglists@googlemail.com"]
  spec.extensions    = Dir["ext/*/extconf.rb"]
  spec.files         = Dir["MIT-LICENSE", "*.md", "docs/**/*.md", "lib/**/*.rb", "ext/**/{*.{c,h,rb},depend,LICENSE}"]
  spec.homepage      = github
  spec.license       = "MIT"
  spec.require_paths = ["lib"]
  spec.summary       = "Fiber And Ractor Compatibility Enabler"

  spec.metadata.merge!({
    bug_tracker_uri: "#{github}/issues",
    changelog_uri:   "#{github}/blob/main/CHANGELOG.md",
    homepage_uri:    github,
    source_code_uri: "#{github}.git",
  }.transform_keys(&:to_s))

  # check statement in README before updating this
  spec.required_ruby_version = ">= 3.4", "< 4.2"
end
