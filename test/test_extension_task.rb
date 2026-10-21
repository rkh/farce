# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

return unless RUBY_ENGINE == "ruby"

require "tmpdir"
require_relative "setup"
require_relative "../rakelib/extension_task"

class TestExtensionTask < Test
  class BuildTask < ExtensionTask
    attr_accessor :configuration
    attr_reader :configuration_runs

    def define_for(platform) = define_compile_tasks(platform)

    private

    def init(...)
      super
      @configuration = { revision: "first", config: { "rubyhdrdir" => "/ruby/include/first" },
                         paths: ["/ruby/first/rbconfig.rb"] }
      @configuration_runs = 0
    end

    def native_configuration_fingerprint = super(**configuration)

    def make_makefile_cmd(*) = ["configure"]

    def sh(*command)
      raise "Unexpected build command: #{command.inspect}" unless command == ["configure"]
      @configuration_runs += 1
      File.write("Makefile", "current configuration")
    end
  end

  def setup
    @previous_application = Rake.application
    Rake.application = Rake::Application.new
    @directory = Dir.mktmpdir("farce-extension-task")
    @previous_directory = Dir.pwd
    Dir.chdir(@directory)
    FileUtils.mkdir_p("ext/example")
    File.write("ext/example/extconf.rb", "")
    @task = BuildTask.new("example")
    @build_path = "tmp/#{RUBY_PLATFORM}/example/#{RUBY_VERSION}"
    @makefile = "#{@build_path}/Makefile"
    @stamp = "#{@build_path}/ruby-config.stamp"
    @object = "#{@build_path}/example.o"
    @binary = "#{@build_path}/example.#{RbConfig::CONFIG.fetch("DLEXT")}"
  end

  def teardown
    Dir.chdir(@previous_directory)
    FileUtils.remove_entry(@directory)
    Rake.application = @previous_application
  end

  def test_defining_tasks_does_not_create_outputs
    refute_path_exists @build_path
    assert_equal 0, @task.configuration_runs
  end

  def test_missing_stamp_removes_stale_outputs_and_preserves_other_builds
    stale = [@makefile, @object, @binary, "#{@build_path}/nested/example.obj"]
    preserved = ["#{@build_path}/keep.txt", "lib/example.#{RbConfig::CONFIG.fetch("DLEXT")}",
                 "tmp/cross-platform/example/#{RUBY_VERSION}/example.o",
                 "tmp/#{RUBY_PLATFORM}/other/#{RUBY_VERSION}/other.o"]
    (stale + preserved).each { write_future_file(it) }

    configure

    assert_equal 1, @task.configuration_runs
    assert_equal "current configuration", File.read(@makefile)
    assert_path_exists @stamp
    stale.drop(1).each { refute_path_exists it }
    preserved.each { assert_equal "cached", File.read(it) }

    assert_path_exists "ext/example/extconf.rb"
  end

  def test_unchanged_configuration_preserves_all_output_timestamps
    configure
    future = Time.now + 3600
    [@makefile, @stamp, @object, @binary].each do |path|
      File.write(path, "cached") unless File.exist?(path)
      File.utime(future, future, path)
    end
    before = [@makefile, @stamp, @object, @binary].to_h { [it, File.mtime(it)] }

    configure
    after = before.keys.to_h { [it, File.mtime(it)] }

    assert_equal 1, @task.configuration_runs
    assert_equal before, after
  end

  def test_changed_header_configuration_invalidates_future_dated_outputs
    assert_configuration_change do
      @task.configuration[:config] = { "rubyhdrdir" => "/ruby/include/second" }
    end
  end

  def test_changed_loaded_configuration_path_invalidates_outputs
    assert_configuration_change { @task.configuration[:paths] = ["/ruby/second/rbconfig.rb"] }
  end

  def test_changed_ruby_revision_invalidates_outputs
    assert_configuration_change { @task.configuration[:revision] = "second" }
  end

  def test_configuration_order_does_not_invalidate_outputs
    @task.configuration[:config] = { "arch" => "example", "rubyhdrdir" => "/ruby/include/first" }
    @task.configuration[:paths] = %w[/ruby/rbconfig.rb /ruby/mkmf.rb]
    configure
    before = File.mtime(@stamp)
    @task.configuration[:config] = @task.configuration[:config].to_a.reverse.to_h
    @task.configuration[:paths].reverse!

    configure

    assert_equal 1, @task.configuration_runs
    assert_equal before, File.mtime(@stamp)
  end

  def test_cross_builds_do_not_depend_on_the_host_configuration
    @task.define_for("cross-platform")
    makefile = Rake::Task["tmp/cross-platform/example/#{RUBY_VERSION}/Makefile"]

    refute(makefile.all_prerequisite_tasks.any? { it.name.include?("ruby-config.stamp") })
  end

  def test_no_native_skips_host_tasks_even_for_explicit_cross_builds_matching_the_host
    Rake.application = Rake::Application.new
    task = BuildTask.new("example") { it.no_native = true }

    refute Rake::Task.task_defined?(@makefile)

    task.define_for(RUBY_PLATFORM)

    assert Rake::Task.task_defined?(@makefile)
    refute(Rake::Task[@makefile].all_prerequisite_tasks.any? { it.name.include?("ruby-config.stamp") })
  end

  private

  def configure
    Rake.application.tasks.each(&:reenable)
    Rake::Task[@makefile].invoke
  end

  def write_future_file(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "cached")
    future = Time.now + 3600
    File.utime(future, future, path)
  end

  def assert_configuration_change
    configure
    previous_stamp = File.binread(@stamp)
    [@makefile, @stamp, @object, @binary].each do |path|
      write_future_file(path) unless path == @stamp
      future = Time.now + 3600
      File.utime(future, future, path)
    end
    yield

    configure

    assert_equal 2, @task.configuration_runs
    refute_equal previous_stamp, File.binread(@stamp)
    refute_path_exists @object
    refute_path_exists @binary
    assert_equal "current configuration", File.read(@makefile)
  end
end
