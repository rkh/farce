# frozen_string_literal: true
# rubocop:disable Naming/VariableNumber, Lint/MissingCopEnableDirective

source "https://rubygems.org"

gemspec

group :development do
  gem "irb"
  gem "rake"
  gem "rake-compiler"
  gem "rake-compiler-dock"
  gem "ruby-lsp", platform: :mri
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

platform :mri_40 do
  group :docs do
    gem "commonmarker"
    gem "yard"
    gem "yard-markdown-relative-links"
  end
end

# Do not use ~> for version constraints in this group, use >= instead
group :compatibility do
  gem "activesupport"
  gem "concurrent-ruby"
  gem "concurrent-ruby-ext"
  gem "dry-types"
  gem "msgpack", ">= 1.8"
  gem "oj", platforms: %i[mri truffleruby]
  gem "ratomic", platforms: %i[mri_34 mri_40]

  # yajl-ruby 1.4.3 uses untyped C data APIs removed in Ruby 4.1.
  gem "yajl-ruby", platforms: %i[mri_34 mri_40 truffleruby]

  platforms :mri_40, :mri_41 do
    gem "ractor-sharing"
    gem "ractor-tmvar", ">= 0.3.0"
  end

  platform :mri do
    gem "async", ">= 2.45"
    gem "ractor_queue"
  end
end

group :benchmark do
  gem "benchmark"
  gem "benchmark-ips"
  gem "lazy_priority_queue"
  gem "philiprehberger-priority_queue"
  gem "pqueue"

  install_if -> { !ENV["CI"] } do
    gem "ractor_safe", platforms: %i[mri_40 mri_41]
  end

  platforms :mri_34, :mri_40 do
    gem "carbon_fiber"
    gem "io-event"
    gem "nio4r"
    gem "priority_queue_cxx", require: "fc"
    gem "rbtree"
  end
end
