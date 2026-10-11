# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# @!group Date Integration
require "farce" unless defined?(Farce::ModeManager)
require "date"  unless defined?(Date)
Farce::ModeManager::SmartRule.define(Date, :make_shareable)
