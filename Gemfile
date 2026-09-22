# frozen_string_literal: true

source "https://gem.coop"

gemspec

group :compatibility do
  gem "concurrent-ruby"
  gem "concurrent-ruby-ext"
  gem "ratomic", platforms: %i[mri_34 mri_40] # rubocop:disable Naming/VariableNumber
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
  platforms :mri_34, :mri_40 do # rubocop:disable Naming/VariableNumber
    gem "carbon_fiber"
    gem "io-event"
    gem "nio4r"
    gem "priority_queue_cxx", require: "fc"
    gem "rbtree"
  end
end

platform :mri_40 do # rubocop:disable Naming/VariableNumber
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

  platforms :mri do
    gem "rubocop"
    gem "rubocop-minitest"
    gem "rubocop-rake"
  end

  gem "simplecov"
  gem "simplecov-console"
end
