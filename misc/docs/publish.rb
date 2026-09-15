# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "cgi"
require "erb"

require "fileutils"
require "json"
require "pathname"

# Assemble the complete Pages tree before handing it to actions-gh-pages.
module DocumentationPages
  MARKER = /<!-- farce-versions:start -->.*?<!-- farce-versions:end -->\n?/m

  def self.publish(source, site, type, name)
    raise ArgumentError, "Missing generated index.html" unless File.file?(File.join(source, "index.html"))
    raise ArgumentError, "Expected main or a tag" unless type == "tag" || (type == "branch" && name == "main")
    if name.split("/", -1).any? { it.empty? || it == "." || it == ".." } || name.include?("\\")
      raise ArgumentError, "Invalid documentation ref"
    end

    path = type == "tag" ? "version/#{name}" : "main"
    manifest = File.join(site, "versions.json")
    versions = File.exist?(manifest) ? JSON.parse(File.read(manifest)) : []
    # Nested tag names work, but a tag cannot occupy another tag's directory.
    if versions.any? { it["path"].start_with?("#{path}/") || path.start_with?("#{it["path"]}/") }
      raise ArgumentError, "Documentation tag paths overlap"
    end

    destination = File.join(site, path)
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp_r(source, destination)
    versions.reject! { it["path"] == path }
    versions.unshift({ "name" => name, "path" => path })
    versions.sort_by! { it["path"] == "main" ? 0 : 1 }
    File.write(manifest, "#{JSON.pretty_generate(versions)}\n")

    versions.each do |version|
      Dir.glob(File.join(site, version.fetch("path"), "**/*.html")).each do |file|
        html = File.read(file).gsub(MARKER, "")
        next if html.include?('<base id="base_target"')

        navigation = switcher(versions, version, file, site)
        container = html.match?(/<div\b[^>]*id="main"[^>]*>/i) ? /<div\b[^>]*id="main"[^>]*>/i : /<body\b[^>]*>/i
        html.sub!(container) { "#{it}\n#{navigation}" }
        File.write(file, html)
      end
    end

    File.write(File.join(site, ".nojekyll"), "")
    target = versions.find { it["path"] == "main" } || versions.first
    url = escape_url("#{target.fetch("path")}/index.html")
    File.write(File.join(site, "index.html"), <<~HTML)
      <!doctype html>
      <html lang="en"><head><meta charset="utf-8"><title>Farce documentation</title>
      <meta http-equiv="refresh" content="0; url=#{url}"></head>
      <body><a href="#{url}">Farce documentation</a></body></html>
    HTML
  end

  def self.escape_url(path)
    CGI.escapeHTML(path.split("/").map { ERB::Util.url_encode(it) }.join("/"))
  end

  def self.switcher(versions, current, file, site)
    options = versions.map do |version|
      target = Pathname.new(File.join(site, version.fetch("path"), "index.html"))
      relative = target.relative_path_from(Pathname.new(File.dirname(file))).to_s
      selected = version == current ? " selected" : ""
      %(<option value="#{escape_url(relative)}"#{selected}>#{CGI.escapeHTML(version.fetch("name"))}</option>)
    end.join("\n")
    <<~HTML
      <!-- farce-versions:start -->
      <nav aria-label="Documentation version" style="display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 12px 48px 12px 16px; background: #eef2f6; color: #222; border-bottom: 1px solid #ccd3db; position: relative; z-index: 10">
        <label for="farce-version">Farce documentation version:</label>
        <select id="farce-version" onchange="window.location.assign(this.value)" style="font: inherit; max-width: 100%; padding: 4px">#{options}</select>
      </nav>
      <!-- farce-versions:end -->
    HTML
  end
end

if $PROGRAM_NAME == __FILE__
  DocumentationPages.publish(*ARGV, ENV.fetch("GITHUB_REF_TYPE"), ENV.fetch("GITHUB_REF_NAME"))
end
