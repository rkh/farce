# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require_relative "setup"
require_relative "../rakelib/update_liburing"
require "fileutils"
require "tmpdir"

class TestLiburingUpdate < Test
  def setup
    @directory = Dir.mktmpdir("farce-liburing-pin")
    @path = File.join(@directory, "liburing.rb")
    @source = <<~RUBY
      # Keep the rest of the build configuration intact.
      module Liburing
        VERSION = "2.15"
        SHA256 = "#{"0" * 64}"

        def self.build = :unchanged
      end
    RUBY
    File.write(@path, @source)
    @downloads = []
    @download = lambda do |url, path|
      @downloads << url
      File.binwrite(path, "upstream archive bytes")
    end
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_updates_both_fields_to_the_highest_stable_release
    version = update(%w[liburing-2.9 liburing-2.16 liburing-2.17-rc1 liburing-2.15])

    assert_equal "2.16", version
    assert_equal ["https://github.com/axboe/liburing/archive/refs/tags/liburing-2.16.tar.gz"], @downloads
    expected = @source.sub('VERSION = "2.15"', 'VERSION = "2.16"')
      .sub("0" * 64, Digest::SHA256.hexdigest("upstream archive bytes"))

    assert_equal expected, File.read(@path)
  end

  def test_skips_the_download_when_the_pin_is_current
    assert_nil update(%w[liburing-2.15 liburing-2.14 liburing-2.16-rc1])
    assert_empty @downloads
    assert_equal @source, File.read(@path)
  end

  def test_does_not_downgrade_the_pin
    assert_nil update(%w[liburing-2.14 liburing-2.9])
    assert_empty @downloads
    assert_equal @source, File.read(@path)
  end

  def test_treats_equivalent_versions_as_unchanged
    assert_nil update(%w[liburing-2.15.0])
    assert_empty @downloads
    assert_equal @source, File.read(@path)
  end

  def test_supports_patch_releases
    assert_equal "2.15.1", update(%w[liburing-2.15 liburing-2.15.1])
    assert_includes File.read(@path), 'VERSION = "2.15.1"'
  end

  def test_rejects_a_release_list_without_stable_tags
    assert_raises(RuntimeError) { update(%w[liburing-2.16-rc1 unrelated]) }
    assert_empty @downloads
    assert_equal @source, File.read(@path)
  end

  def test_does_not_modify_an_unrecognized_pin_file
    source = @source.sub("SHA256", "UNEXPECTED")
    File.write(@path, source)

    assert_raises(RuntimeError) { update(%w[liburing-2.16]) }
    assert_empty @downloads
    assert_equal source, File.read(@path)
  end

  def test_download_failure_preserves_the_existing_pin
    download = lambda do |_url, path|
      File.write(path, "partial download")
      raise "download failed"
    end

    assert_raises(RuntimeError) { LiburingUpdate.run(path: @path, tags: %w[liburing-2.16], download:) }
    assert_equal @source, File.read(@path)
  end

  private

  def update(tags)
    LiburingUpdate.run(path: @path, tags:, download: @download)
  end
end
