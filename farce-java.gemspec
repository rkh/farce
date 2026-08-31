# frozen_string_literal: true

Gem::Specification.load("farce.gemspec").dup.tap do |spec|
  spec.extensions = []
  spec.files      = spec.files.reject { it.start_with?("ext/") }
  spec.licenses   = ["MIT"]
  spec.platform   = "java"
end
