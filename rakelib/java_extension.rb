# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "zlib"

# The JAR ships in source gems too, so TruffleRuby never needs javac on install.
module JavaExtension
  ROOT = File.expand_path("..", __dir__)
  JAR = "lib/farce/engine/jvm/farce.jar"
  CLASSES = %w[
    org/farce/BoundedMap$Bucket.class
    org/farce/BoundedMap$Entry.class
    org/farce/BoundedMap$LFUEntry.class
    org/farce/BoundedMap.class
    org/farce/PriorityKey.class
    org/farce/PriorityQueue$Bucket.class
    org/farce/PriorityQueue$Entry.class
    org/farce/PriorityQueue$Failure.class
    org/farce/PriorityQueue$TrackedEntry.class
    org/farce/PriorityQueue.class
    org/farce/QueueSignal.class
  ].freeze
  SCHEDULER_JAR = "lib/farce/engine/jruby/fiber_scheduler.jar"
  SCHEDULER_CLASSES = %w[org/farce/FiberScheduler.class].freeze
  JARS = [JAR, SCHEDULER_JAR].freeze
  CLASS_VERSION = 61 # Both jars target Java 17; only the scheduler jar uses JRuby APIs.

  module_function

  def build
    Dir.mktmpdir("farce-java") do |stage|
      sources = Dir[File.join(ROOT, "ext/java/**/*.java")].reject { File.basename(it) == "FiberScheduler.java" }
      run(ENV.fetch("JAVAC", "javac"), "--release", "17", "-d", stage, *sources)
      output = File.join(stage, "farce.jar")
      # Stored entries permit dependency-free bytecode validation in GemVerifier.
      # Fixed mtimes and no manifest keep the release artifact reproducible.
      FileUtils.touch(Dir["#{stage}/**/*"], mtime: Time.utc(2000))
      run(ENV.fetch("JAR", "jar"), "--create", "--file", output,
        "--no-compress", "--no-manifest", "-C", stage, "org")
      validate(File.binread(output))
      FileUtils.cp(output, File.join(ROOT, JAR))
    end
  end

  def build_scheduler
    require "rbconfig"
    jar = ENV["JRUBY_JAR"]
    if !jar && RUBY_ENGINE == "jruby"
      require "jruby"
      jar = File.join(JRuby.runtime.jruby_home, "lib", "jruby.jar")
    end
    unless jar && File.file?(jar)
      raise "Set JRUBY_JAR to lib/jruby.jar from the JRuby runtime used to build scheduler bindings"
    end
    Dir.mktmpdir("farce-scheduler-java") do |stage|
      run(ENV.fetch("JAVAC", "javac"), "--release", "17", "-proc:none", "-classpath", jar,
        "-d", stage, File.join(ROOT, "ext/java/org/farce/FiberScheduler.java"))
      FileUtils.touch(Dir["#{stage}/**/*"], mtime: Time.utc(2000))
      output = File.join(stage, "scheduler.jar")
      run(ENV.fetch("JAR", "jar"), "--create", "--file", output,
        "--no-compress", "--no-manifest", "-C", stage, "org")
      validate(File.binread(output), expected_classes: SCHEDULER_CLASSES)
      FileUtils.mkdir_p(File.dirname(File.join(ROOT, SCHEDULER_JAR)))
      FileUtils.cp(output, File.join(ROOT, SCHEDULER_JAR))
    end
  end

  def run(*command)
    return if system({ "TZ" => "UTC" }, *command)
    raise "Java extension build failed: #{command.first} (set JAVAC/JAR to your JDK tools)"
  end

  # Accept the deliberately simple JAR format emitted above, check every CRC,
  # and reject missing/unexpected classes or bytecode requiring a newer JVM.
  def validate(bytes, expected_classes: CLASSES)
    raise "missing Java extension" unless bytes

    offset = 0
    classes = []
    while bytes.byteslice(offset, 4) == "PK\x03\x04"
      header = bytes.byteslice(offset + 4, 26)
      raise "truncated Java archive" unless header&.bytesize == 26
      _version, flags, method, _time, _date, crc, compressed, size, name_size, extra_size = header.unpack("v5V3v2")
      unless flags.nobits?(8) && method.zero? && compressed == size
        raise "Java archive must use stored entries without data descriptors"
      end
      name = bytes.byteslice(offset + 30, name_size)
      offset += 30 + name_size + extra_size
      content = bytes.byteslice(offset, size)
      raise "corrupt Java archive entry #{name}" unless content&.bytesize == size && Zlib.crc32(content) == crc
      offset += size
      next if name.end_with?("/")

      unless content.byteslice(0, 4) == "\xCA\xFE\xBA\xBE".b &&
          content.byteslice(4, 4)&.unpack("n2") == [0, CLASS_VERSION]
        raise "#{name} must contain Java 17 bytecode without preview features"
      end
      classes << name
    end
    unless classes.sort == expected_classes.sort && bytes.byteslice(offset, 4) == "PK\x01\x02"
      raise "Java archive has missing or unexpected classes"
    end
    "Java 17 bytecode (#{classes.join(", ")})"
  end
end
