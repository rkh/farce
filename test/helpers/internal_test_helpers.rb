# frozen_string_literal: true

if RUBY_ENGINE == "ruby"
  internal = Farce.const_get(:Internal, false)
  %i[Atom Counter Exchanger Flag Map Queue Signal Unshareable Vector WeakMap WeakKeyMap WeakValueMap].each do |name|
    internal.__send__(:remove_const, name) if internal.autoload?(name)
  end
  version = RUBY_VERSION[/^\d+\.\d+/]
  require "farce/engine/ruby/#{version}/containers"
end

module Helpers
  module InternalTestHelpers
    def shared_string(value)
      value.dup.freeze
    end

    def ractor_value(ractor)
      ractor.respond_to?(:value) ? ractor.value : ractor.take
    end

    def open_file_descriptor_count
      directory = ["/dev/fd", "/proc/self/fd"].find { |path| File.directory?(path) }
      directory && Dir.children(directory).length
    rescue SystemCallError
      nil
    end
  end
end
