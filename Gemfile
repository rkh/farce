# frozen_string_literal: true
# rubocop:disable Naming/VariableNumber, Lint/MissingCopEnableDirective

source "https://rubygems.org"

gemspec

group :compatibility do
  gem "concurrent-ruby"
  gem "concurrent-ruby-ext"
  gem "ratomic", platforms: %i[mri_34 mri_40]
  platform :mri do
    gem "async", "~> 2.45"
    gem "ractor_queue"
  end
end

group :development do
  gem "irb"
  gem "rake"
  gem "rake-compiler"
  gem "rake-compiler-dock"
  gem "ruby-lsp", platform: :mri
end

group :benchmark do
  gem "benchmark"
  gem "benchmark-ips"
  gem "lazy_priority_queue"
  gem "philiprehberger-priority_queue"
  gem "pqueue"

  platforms :mri_40, :mri_41 do
    gem "ractor-sharing"
    # TODO: Switch to official gem once https://github.com/yoshitsugu/ractor-tmvar/pull/1 has been merged and released
    gem "ractor-tmvar", github: "rkh/ractor-tmvar", branch: "patch-1"
    install_if -> { !ENV["CI"] } do
      gem "ractor_safe"
    end
  end

  platforms :mri_34, :mri_40 do
    gem "carbon_fiber"
    gem "io-event"
    gem "nio4r"
    gem "priority_queue_cxx", require: "fc"
    gem "rbtree"
  end
end

platform :mri_40 do
  group :docs do
    gem "commonmarker"
    gem "yard"
    gem "yard-markdown-relative-links"
  end
end

group :test do
  gem "activesupport"
  gem "dry-types"
  gem "minitest"
  gem "minitest-reporters"
  gem "msgpack", "~> 1.8"
  gem "oj", platforms: %i[mri truffleruby]
  # yajl-ruby 1.4.3 uses untyped C data APIs removed in Ruby 4.1.
  gem "yajl-ruby", platforms: %i[mri_34 mri_40 truffleruby]

  platforms :mri do
    gem "rubocop"
    gem "rubocop-minitest"
    gem "rubocop-rake"
  end

  gem "simplecov"
  gem "simplecov-console"
end
