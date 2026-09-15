# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "minitest/autorun"
require "tmpdir"
require_relative "publish"

class DocumentationPagesTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @source = File.join(@tmp, "source")
    @site = File.join(@tmp, "pages")
    FileUtils.mkdir_p(File.join(@source, "Farce"))
    File.write(File.join(@source, "index.html"), "<html><body>Index</body></html>")
    File.write(File.join(@source, "Farce/Queue.html"), "<html><body>Queue</body></html>")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def publish(type, name)
    DocumentationPages.publish(@source, @site, type, name)
  end

  def test_versions_are_preserved_and_old_switchers_are_updated
    publish("branch", "main")
    publish("tag", "v1.0.0")
    publish("tag", "v2.0.0")

    page = File.read(File.join(@site, "main/Farce/Queue.html"))
    assert_includes page, 'value="../../version/v2.0.0/index.html"'
    assert_includes page, 'value="../index.html" selected>main'
    assert_includes File.read(File.join(@site, "version/v1.0.0/index.html")), ">v2.0.0</option>"
    assert_equal 1, page.scan("<!-- farce-versions:start -->").size
    assert File.exist?(File.join(@site, ".nojekyll"))
  end

  def test_rebuild_removes_stale_pages_and_keeps_other_versions
    publish("tag", "v1")
    publish("branch", "main")
    FileUtils.rm(File.join(@source, "Farce/Queue.html"))
    publish("branch", "main")

    refute_path_exists File.join(@site, "main/Farce/Queue.html")
    assert_path_exists File.join(@site, "version/v1/Farce/Queue.html")
    assert_includes File.read(File.join(@site, "index.html")), "url=main/index.html"
  end

  def test_selector_uses_the_content_panel_and_skips_sidebar_frames
    File.write(File.join(@source, "index.html"), '<body><div id="main" tabindex="-1">Content</div></body>')
    File.write(File.join(@source, "class_list.html"),
      '<head><base id="base_target" target="_parent"></head><body>List</body>')
    publish("branch", "main")

    page = File.read(File.join(@site, "main/index.html"))
    assert_match(/<div id="main" tabindex="-1">\s*<!-- farce-versions:start -->/, page)
    refute_includes File.read(File.join(@site, "main/class_list.html")), "farce-versions:start"
  end

  def test_nested_tags_and_escaping
    publish("tag", 'release/v1&"')
    page = File.read(File.join(@site, 'version/release/v1&"/index.html'))

    assert_includes page, "release/v1&amp;&quot;</option>"
    assert_includes File.read(File.join(@site, "index.html")), "version/release/v1%26%22/index.html"
    assert_raises(ArgumentError) { publish("tag", "release") }
    assert_raises(ArgumentError) { publish("tag", "../outside") }
    assert_raises(ArgumentError) { publish("branch", "feature") }
  end
end
