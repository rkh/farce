# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "digest"
require "fileutils"
require "rbconfig"
require "tmpdir"

# Build a private liburing with the cross-Ruby compiler, without adding a runtime dependency.
module Liburing
  VERSION = "2.15"
  SHA256 = "8d052f2622dcb3678cbaee5ff582a87572672a6c0a56533cdda5b65cb636120a"

  module_function

  def build(prefix)
    library = File.join(prefix, "lib/liburing.a")
    return if File.file?(library)

    Dir.mktmpdir("farce-liburing") do |stage|
      archive = File.join(stage, "liburing.tar.gz")
      run("curl", "--fail", "--location", "--retry", "3",
        "https://github.com/axboe/liburing/archive/refs/tags/liburing-#{VERSION}.tar.gz", "--output", archive)
      raise "liburing #{VERSION} SHA256 mismatch" unless Digest::SHA256.file(archive).hexdigest == SHA256
      run("tar", "-xzf", archive, "-C", stage)

      source = File.join(stage, "liburing-liburing-#{VERSION}")
      # These tools come from fake.rb's target RbConfig, not the container's host Ruby.
      tools = RbConfig::CONFIG.slice("CC", "AR", "RANLIB").merge("CFLAGS" => "-O2 -fPIC")
      Dir.chdir(source) do
        run(tools, "./configure", "--cc=#{tools.fetch("CC")}")
        run(tools, "make", "-C", "src", "-j2", "liburing.a")
      end

      FileUtils.mkdir_p([File.join(prefix, "include"), File.dirname(library)])
      FileUtils.cp_r(File.join(source, "src/include/liburing"), File.join(prefix, "include"))
      FileUtils.cp(File.join(source, "src/include/liburing.h"), File.join(prefix, "include"))
      FileUtils.cp(File.join(source, "src/liburing.a"), "#{library}.tmp")
      File.rename("#{library}.tmp", library)
    end
  end

  def run(*command)
    system(*command, exception: true)
  end
end

if $PROGRAM_NAME == __FILE__
  require File.expand_path(ARGV.fetch(0))
  Liburing.build(File.expand_path(ARGV.fetch(1)))
end
