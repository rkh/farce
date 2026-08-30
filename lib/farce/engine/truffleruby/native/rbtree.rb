# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

begin
  require_relative "#{RUBY_ENGINE_VERSION}/rbtree"
  autoload :TreeMap, "farce/engine/ruby/shared/tree_map"
rescue LoadError => e
  # simplecov:disable
  warn <<~WARNING
    Farce: Failed to load native extension for TruffleRuby #{RUBY_ENGINE_VERSION}.
    Please run `rake compile` to build the extension.
  WARNING
  raise e
  # simplecov:enable
end
