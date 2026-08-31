# frozen_string_literal: true

source "https://gem.coop"

gemspec

group :compatibility do
  gem "concurrent-ruby"
  gem "ratomic", platforms: %i[mri_34 mri_40]
  platform :mri do
    gem "async", "~> 2.45"
    gem "concurrent-ruby-ext"
    gem "ractor_queue"
  end
end

group :development do
  gem "benchmark-ips"
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
