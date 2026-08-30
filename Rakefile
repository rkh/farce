# frozen_string_literal: true

require "bundler/setup"
require "rake/clean"

# Platforms we ship prebuilt gems for.
CROSS_PLATFORMS = %w[
  aarch64-mingw-ucrt
  x64-mingw-ucrt

  aarch64-linux
  arm-linux
  x86_64-linux
  x86-linux

  arm64-darwin
  x86_64-darwin

  jruby
].freeze

task default: %i[compile test rubocop]
