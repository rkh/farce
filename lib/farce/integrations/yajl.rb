# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group Yajl Integration
# Yajl 1.4.3 cannot encode or parse inside non-main native Ractors.
require "farce"
require "yajl" unless defined?(Yajl::Encoder)
require "json" unless [].respond_to?(:to_json)
require_relative "shared/to_json"
