# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  # @!visibility private
  module Internal # :nodoc: all
    begin
      require "#{ENGINE_PATH}/containers"
    rescue LoadError => e
      warn <<~WARNING
        Farce: Failed to load native extension for Ruby #{RUBY_VERSION}.
        Please run `rake compile` to build the extension.
      WARNING
      raise e
    end

    require_relative "shared/weak_map" unless const_defined?(:NATIVE_WEAK_MAPS, false) && NATIVE_WEAK_MAPS
  end
end
