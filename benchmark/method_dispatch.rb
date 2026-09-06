# frozen_string_literal: true
# warn_indent: true

require "benchmark/ips"

class Direct
  def call = 42
end

class Included
  module Mixin
    def call = 42
  end
  include Mixin
  def unrelated = 42
end

class Prepended
  module Mixin
    def call = 42
  end
  prepend Mixin
  def unrelated = 42
end

class Extended
  module Mixin
    def call = 42
  end
  def initialize = extend Mixin
  def unrelated = 42
end

Benchmark.ips do |x|
  [Direct, Included, Prepended, Extended].each do |klass|
    instance = klass.new
    x.report("#{klass.name}#call") do |times|
      count = 0
      while count < times
        instance.call
        count += 1
      end
    end

    if instance.respond_to?(:unrelated)
      x.report("#{klass.name}#unrelated") do |times|
        count = 0
        while count < times
          instance.unrelated
          count += 1
        end
      end
    end
  end

  x.compare!
end
