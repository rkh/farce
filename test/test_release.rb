# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

require "rake"
require "tmpdir"
require_relative "setup"
require_relative "../rakelib/release_notes"
require_relative "../rakelib/gem_verifier"

class TestReleaseNotes < Test
  def test_extracts_only_the_requested_release_and_promotes_all_headings
    changelog = <<~MARKDOWN
      # Changelog
      ## Development Releases
      ### Farce 0.3.0 (2026-10-13)
      Upcoming release.
      ### Farce 0.2.0 (2026-10-11)

      #### New Features
      ##### Flags
      ###### Details
      Release notes.

      ### Farce 0.1.0 (2026-10-09)
      Initial release.
    MARKDOWN
    expected = <<~MARKDOWN
      # Farce 0.2.0 (2026-10-11)

      ## New Features
      ### Flags
      #### Details
      Release notes.
    MARKDOWN

    assert_equal expected, ReleaseNotes.extract(changelog, "0.2.0")
  end

  def test_preserves_fenced_examples_and_ignores_headings_inside_them
    changelog = <<~MARKDOWN
      ### Farce 0.2.0
      #### Examples
      ````markdown
      ### Farce 9.9.9
      #### Keep this heading
      ```
      ````
      ~~~ruby
      # Keep this comment
      ### Farce 0.1.0
      ~~~
      #### After examples
      ### Farce 0.1.0
      Previous release.
    MARKDOWN
    expected = changelog.sub("### Farce 0.2.0", "# Farce 0.2.0")
      .sub("#### Examples", "## Examples")
      .sub("#### After examples", "## After examples")
      .sub("### Farce 0.1.0\nPrevious release.\n", "")

    assert_equal expected, ReleaseNotes.extract(changelog, "0.2.0")
  end

  def test_stops_at_a_parent_heading
    assert_equal "# Farce 0.2.0\nNotes.\n", ReleaseNotes.extract(
      "### Farce 0.2.0\nNotes.\n## Older releases\n### Farce 0.1.0\nOld.\n", "0.2.0",
    )
  end

  def test_matches_the_exact_version_including_prereleases
    changelog = "### Farce 0.2.0.alpha1\nNotes.\n"

    assert_equal "# Farce 0.2.0.alpha1\nNotes.\n", ReleaseNotes.extract(changelog, "0.2.0.alpha1")
    assert_raises(RuntimeError) { ReleaseNotes.extract(changelog, "0.2.0") }
    assert_raises(RuntimeError) { ReleaseNotes.extract(changelog, "0x2x0xalpha1") }
  end

  def test_rejects_a_missing_section_even_when_an_example_mentions_the_version
    error = assert_raises(RuntimeError) do
      ReleaseNotes.extract("```markdown\n### Farce 0.2.0\n```\n", "0.2.0")
    end

    assert_equal "CHANGELOG.md has no section for Farce 0.2.0", error.message
  end
end

class TestReleaseTask < Test
  def test_validates_changelog_before_verifying_or_publishing_gems
    with_release do
      File.write("CHANGELOG.md", "### Farce 0.1.0\nOld release.\n")

      assert_raises(RuntimeError) { Rake::Task["release"].invoke }
      assert_empty @commands
    end
  end

  def test_accepts_both_tag_formats_and_rejects_non_tags_or_mismatched_versions
    with_release do
      %w[0.2.0 v0.2.0].each do |tag|
        ENV["GITHUB_REF_NAME"] = tag
        Rake::Task["release:validate"].reenable
        Rake::Task["release:validate"].invoke
      end
      ENV["GITHUB_REF_TYPE"] = "branch"
      Rake::Task["release:validate"].reenable
      assert_raises(RuntimeError) { Rake::Task["release:validate"].invoke }
      ENV["GITHUB_REF_TYPE"] = "tag"
      ENV["GITHUB_REF_NAME"] = "v0.1.0"
      Rake::Task["release:validate"].reenable
      assert_raises(RuntimeError) { Rake::Task["release:validate"].invoke }
    end
  end

  def test_creates_github_release_after_all_verified_gems_are_uploaded
    with_release do
      Rake::Task["release"].invoke

      assert_equal :verify, @commands.first
      uploads = @commands[1...-1]

      assert_equal 3, uploads.length
      assert_equal Dir["pkg/*.gem"], uploads.map(&:last)
      assert(uploads.all? { it[0...4] == ["gem", "push", "--host", "https://rubygems.org"] })
      assert_equal ["gh", "release", "create", "v0.2.0", "--repo", "rkh/farce", "--verify-tag", "--notes-file"],
        @commands.last[0...-1]
      assert_equal "# Farce 0.2.0\n## Features\nNotes.\n", @github_notes
      refute_path_exists @commands.last.last
    end
  end

  def test_does_not_create_github_release_if_an_upload_fails
    with_release(fail_on_upload: 2) do
      assert_raises(RuntimeError) { Rake::Task["release"].invoke }
      assert_equal(2, @commands.count { it.is_a?(Array) && it.first == "gem" })
      refute(@commands.any? { it.is_a?(Array) && it.first == "gh" })
    end
  end

  def test_rejects_missing_artifacts_before_publishing
    with_release do
      File.delete("pkg/farce-0.2.0-java.gem")

      assert_raises(RuntimeError) { Rake::Task["release"].invoke }
      assert_equal [:verify], @commands
    end
  end

  def test_marks_prereleases_on_github
    with_release(version: "0.3.0.alpha1") do
      Rake::Task["release"].invoke

      assert_equal "--prerelease", @commands.last.last
    end
  end

  private

  def with_release(version: "0.2.0", fail_on_upload: nil)
    previous_application = Rake.application
    previous_env = ENV.to_h.slice("GITHUB_REF_NAME", "GITHUB_REF_TYPE", "GITHUB_REPOSITORY")
    ENV.update("GITHUB_REF_NAME" => "v#{version}", "GITHUB_REF_TYPE" => "tag", "GITHUB_REPOSITORY" => "rkh/farce")
    Rake.application = Rake::Application.new
    @commands = []
    commands = @commands
    context = Module.new
    context.extend(Rake::DSL)
    context.const_set(:CROSS_PLATFORMS, %w[x86_64-linux-gnu jruby])
    specification = Gem::Specification.new do |spec|
      spec.name = "farce"
      spec.version = version
    end
    loader = Object.new
    loader.define_singleton_method(:load) { |_path| specification }
    context.const_set(:Gem, Module.new).const_set(:Specification, loader)
    test = self
    context.define_singleton_method(:sh) do |*arguments|
      commands << arguments
      if arguments.first == "gh"
        test.instance_variable_set(:@github_notes, File.read(arguments[arguments.index("--notes-file") + 1]))
      elsif commands.count { it.is_a?(Array) && it.first == "gem" } == fail_on_upload
        raise "Upload failed"
      end
    end
    Rake::Task.define_task("gem:verify") { commands << :verify }
    path = File.expand_path("../rakelib/release.rake", __dir__)
    context.module_eval(File.read(path), path)

    Dir.mktmpdir("farce-release-test") do |directory|
      Dir.chdir(directory) do
        File.write("CHANGELOG.md", "### Farce #{version}\n#### Features\nNotes.\n")
        Dir.mkdir("pkg")
        [nil, "x86_64-linux-gnu", "java"].each do |platform|
          File.write("pkg/farce-#{version}#{"-#{platform}" if platform}.gem", "")
        end
        yield
      end
    end
  ensure
    Rake.application = previous_application
    %w[GITHUB_REF_NAME GITHUB_REF_TYPE GITHUB_REPOSITORY].each { ENV[it] = previous_env[it] }
  end
end
