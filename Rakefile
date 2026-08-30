# frozen_string_literal: true

require "bundler/setup"
require "rake/clean"

# Platforms we ship prebuilt gems for.
CROSS_PLATFORMS = %w[
  aarch64-linux-gnu
  aarch64-linux-musl

  arm-linux-gnu
  arm-linux-musl

  x86_64-linux-gnu
  x86_64-linux-musl

  x86-linux-gnu
  x86-linux-musl

  aarch64-mingw-ucrt
  x64-mingw-ucrt

  arm64-darwin
  x86_64-darwin

  jruby
].freeze

task default: %i[compile test rubocop]
