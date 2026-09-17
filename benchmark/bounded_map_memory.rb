# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

# Account for native backing storage separately from user keys and values.
require "farce"
require "objspace"

abort "This measurement requires the CRuby native backend" unless RUBY_ENGINE == "ruby"

sizes = ENV.fetch("SIZES", "16,1024,65536").split(",").map { Integer(it) }
churn = Integer(ENV.fetch("CHURN", "5"))
raise ArgumentError, "positive sizes and nonnegative churn required" unless sizes.all?(&:positive?) && churn >= 0

internal = Farce.const_get(:Internal)
puts RUBY_DESCRIPTION
puts "ObjectSpace-accounted native storage only; excludes payload objects, " \
     "wrapper/helper objects, and allocator overhead."
puts "Integer keys and values; churn replaces each capacity #{churn} times."
puts "size,backend,empty_bytes,filled_bytes,bytes_per_entry,churn_bytes,cleared_bytes"

sizes.each do |size|
  %i[LRUMap LFUMap].each do |name|
    map = internal.const_get(name).new(max_size: size)
    empty = ObjectSpace.memsize_of(map)
    size.times { |index| map[index] = index }
    filled = ObjectSpace.memsize_of(map)
    (size * churn).times { |index| map[size + index] = index }
    after_churn = ObjectSpace.memsize_of(map)
    map.clear
    cleared = ObjectSpace.memsize_of(map)
    puts [size, name, empty, filled, format("%.2f", (filled - empty).fdiv(size)), after_churn, cleared].join(",")
  end
end

# Distinct frequency buckets are the LFU storage extreme. Limit this quadratic
# setup to 1024 entries so the default measurement stays inexpensive.
frequency_size = [sizes.max, 1024].min
map = internal.const_get(:LFUMap).new(max_size: frequency_size)
frequency_size.times { |index| map[index] = index }
shared_bucket = ObjectSpace.memsize_of(map)
frequency_size.times { |index| index.times { map[index] } }
separate_buckets = ObjectSpace.memsize_of(map)
puts "LFU #{frequency_size} entries: one bucket #{shared_bucket} bytes; distinct frequencies #{separate_buckets} bytes."
