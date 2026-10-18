# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "digest"
require "open3"
require "rubygems/version"
require "tempfile"
require "tmpdir"

# Refresh the reviewed liburing pin from stable upstream releases.
module LiburingUpdate
  module_function

  def run(path: File.expand_path("liburing.rb", __dir__), tags: release_tags, download: method(:download))
    version = tags.filter_map { /\Aliburing-(\d+\.\d+(?:\.\d+)*)\z/.match(it)&.[](1) }
      .max_by { Gem::Version.new(it) }
    raise "No stable liburing release found" unless version

    source = File.read(path)
    version_pattern = /^  VERSION = "(\d+\.\d+(?:\.\d+)*)"$/
    checksum_pattern = /^  SHA256 = "[a-f0-9]{64}"$/
    current = version_pattern.match(source)&.[](1)
    raise "Cannot find the liburing version and SHA256 pin" unless current && checksum_pattern.match?(source)
    return if Gem::Version.new(version) <= Gem::Version.new(current)

    Dir.mktmpdir("farce-liburing-update") do |directory|
      archive = File.join(directory, "liburing.tar.gz")
      download.call("https://github.com/axboe/liburing/archive/refs/tags/liburing-#{version}.tar.gz", archive)
      checksum = Digest::SHA256.file(archive).hexdigest
      updated = source.sub(version_pattern, "  VERSION = \"#{version}\"")
        .sub(checksum_pattern, "  SHA256 = \"#{checksum}\"")

      Tempfile.create(["liburing-pin", ".rb"], File.dirname(path)) do |file|
        file.write(updated)
        file.chmod(File.stat(path).mode & 0o777)
        file.close
        File.rename(file.path, path)
      end
    end
    version
  end

  def release_tags
    query = ".[] | select(.draft == false and .prerelease == false) | .tag_name"
    output, error, status = Open3.capture3("gh", "api", "--paginate",
      "repos/axboe/liburing/releases?per_page=100", "--jq", query)
    raise "Cannot fetch liburing releases: #{error}" unless status.success?
    output.lines.map(&:strip)
  end

  def download(url, path)
    system("curl", "--fail", "--location", "--retry", "3", url, "--output", path, exception: true)
  end
end

if $PROGRAM_NAME == __FILE__
  version = LiburingUpdate.run
  puts(version ? "Updated liburing to #{version}" : "The liburing pin is already current")
  if ENV["GITHUB_OUTPUT"]
    File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |output|
      output.puts("changed=#{!version.nil?}")
      output.puts("version=#{version}") if version
    end
  end
end
