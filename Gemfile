# frozen_string_literal: true

source "https://gem.coop"

gemspec

group :development do
  gem "irb"
  gem "rake"
  gem "rake-compiler"
  gem "rake-compiler-dock"
  gem "ruby-lsp", platform: :mri
  gem "yard"
  gem "yard-markdown-relative-links"
end

group :test do
  gem "minitest"
  gem "minitest-reporters"

  platforms :mri do
    gem "rubocop"
    gem "rubocop-minitest"
    gem "rubocop-rake"
  end

  gem "simplecov"
  gem "simplecov-console"
end
