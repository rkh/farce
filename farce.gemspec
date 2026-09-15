# frozen_string_literal: true

require_relative "lib/farce/version"
require_relative "ext/ext_helper"

github          = "https://github.com/rkh/farce"
homepage        = "https://rkh.github.io/farce"
extension_names = %w[farce rebind].freeze
extension_files = extension_names.flat_map do |name|
  Dir["ext/#{name}/{*.{c,h,rb},depend,*LICENSE,README.md}"]
end

extension_files << "ext/ext_helper.rb"
extension_files.concat(Dir["ext/java/**/*.java"])

Gem::Specification.new("farce", Farce::VERSION) do |spec|
  spec.authors    = ["Konstantin Haase"]
  spec.email      = ["konstantin.mailinglists@googlemail.com"]
  spec.extensions = extension_names.map { "ext/#{it}/extconf.rb" }
  spec.files      = (Dir["MIT-LICENSE", "*.md", "docs/**/*.md", "lib/**/*.{rb,jar}"] + extension_files).sort
  spec.homepage   = homepage
  # Farce's own code is MIT-licensed. The native priority queue also vendors
  # Kazlib 1.20's permissively licensed dict.c/dict.h; Kazlib's terms do not
  # have an SPDX identifier, so RubyGems' supported LicenseRef form is used.
  spec.licenses   = ["MIT", "LicenseRef-Kazlib-1.20"]
  spec.summary    = "Fiber And Ractor Compatibility Enabler"

  spec.metadata.merge!({
    bug_tracker_uri: "#{github}/issues",
    changelog_uri:   "#{github}/blob/main/CHANGELOG.md",
    homepage_uri:    homepage,
    source_code_uri: "#{github}.git",
  }.transform_keys(&:to_s))

  # check statement in README before updating this
  spec.required_ruby_version = ">= 3.4", "< 4.2"
end
