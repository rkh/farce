# frozen_string_literal: true

require_relative "../ext/ext_helper"
require_relative "java_extension"
require "rubygems/package"
require "zlib"

# Checks that a built gem ships the binaries it claims to, built for the platform it claims.
# Cross compilation happens out of sight in a container, so a gem that quietly ends up holding
# the wrong architecture looks exactly like a good one until someone installs it.
module GemVerifier
  class Error < StandardError
  end

  # Platform => [dlext, expected binary description]
  SIGNATURES = {
    "aarch64-linux-gnu"  => ["so",     "ELF 64-bit aarch64 GNU libc"],
    "aarch64-linux-musl" => ["so",     "ELF 64-bit aarch64 musl libc"],
    "aarch64-mingw-ucrt" => ["so",     "PE 64-bit aarch64"],
    "arm-linux-gnu"      => ["so",     "ELF 32-bit arm GNU libc"],
    "arm-linux-musl"     => ["so",     "ELF 32-bit arm musl libc"],
    "arm64-darwin"       => ["bundle", "Mach-O 64-bit arm64"],
    "x64-mingw-ucrt"     => ["so",     "PE 64-bit x86_64"],
    "x86-linux-gnu"      => ["so",     "ELF 32-bit i386 GNU libc"],
    "x86-linux-musl"     => ["so",     "ELF 32-bit i386 musl libc"],
    "x86_64-darwin"      => ["bundle", "Mach-O 64-bit x86_64"],
    "x86_64-linux-gnu"   => ["so",     "ELF 64-bit x86_64 GNU libc"],
    "x86_64-linux-musl"  => ["so",     "ELF 64-bit x86_64 musl libc"],
  }.freeze

  # JVM targets share portable bytecode, with no native binaries or install-time compiler.
  JVM_PLATFORMS = { "jruby" => "java" }.freeze

  ELF_MACHINES  = { 0x03 => "i386", 0x28 => "arm", 0x3e => "x86_64", 0xb7 => "aarch64" }.freeze
  PE_MACHINES   = { 0x014c => "i386", 0x8664 => "x86_64", 0xaa64 => "aarch64" }.freeze
  MACH_O_CPUS   = { 0x07 => "i386", 0x0c => "arm", 0x01000007 => "x86_64", 0x0100000c => "arm64" }.freeze
  MACH_O_MAGICS = { 0xfeedface => 32, 0xfeedfacf => 64 }.freeze

  UNKNOWN = "an unrecognized binary format"
  BINARY  = /\.(?:so|bundle|dylib|dll|jar|class)\z/

  extend self

  # Every build target these checks know something about.
  def targets
    SIGNATURES.keys + JVM_PLATFORMS.keys
  end

  # The platform a target's gem declares, which is not always the target's own name.
  def gem_platform(target)
    JVM_PLATFORMS.fetch(target, target)
  end

  # Each target produces a different kind of gem, so each gets a different set of checks.
  def verify(gem_file, platform:, abis:, names:)
    return verify_source(gem_file) if platform.nil?
    return verify_java(gem_file, platform:) if JVM_PLATFORMS.key?(platform)
    verify_platform(gem_file, platform:, abis:, names:)
  end

  # Returns the checks that passed, keyed by label, so callers can show their work.
  def verify_platform(gem_file, platform:, abis:, names:)
    dlext, expected = SIGNATURES.fetch(platform) { raise Error, "no known signature for #{platform}" }
    spec            = spec(gem_file)
    files           = files(gem_file)

    raise Error, "declares platform #{spec.platform}, expected #{platform}" unless spec.platform.to_s == platform
    unless spec.extensions.empty?
      raise Error, "declares extension #{spec.extensions.join(", ")}, so it would compile on install"
    end

    wanted = names.product(abis).to_h do |name, abi|
      ["#{ExtHelper.ext_path(name, version: abi, lib: true)}.#{dlext}", abi]
    end

    extra = files.keys.grep(BINARY) - wanted.keys - JavaExtension::JARS
    raise Error, "ships #{extra.join(", ")}, which no supported Ruby would load" if extra.any?

    checks = { "platform" => platform, "extensions" => "none" }
    checks.merge!(verify_java_extensions(files))

    wanted.each do |path, abi|
      found = describe(files[path])
      raise Error, "#{path}: expected #{expected}, found #{found}" unless found == expected
      unless spec.required_ruby_version.satisfied_by?(Gem::Version.new(abi))
        raise Error, "ships #{path} but required_ruby_version (#{spec.required_ruby_version}) excludes #{abi}"
      end
      checks[path] = found
    end

    checks
  end

  # The Java gem ships Ruby and portable bytecode, without native extensions or sources.
  def verify_java(gem_file, platform:)
    expected = JVM_PLATFORMS.fetch(platform)
    spec     = spec(gem_file)
    files    = files(gem_file)

    raise Error, "declares platform #{spec.platform}, expected #{expected}" unless spec.platform.to_s == expected
    unless spec.extensions.empty?
      raise Error, "declares extension #{spec.extensions.join(", ")}, so it would compile on install"
    end

    binaries = files.keys.grep(BINARY) - JavaExtension::JARS
    sources  = files.keys.grep(%r{\Aext/})
    raise Error, "ships #{binaries.join(", ")}, which #{platform} cannot load" if binaries.any?
    raise Error, "ships #{sources.join(", ")}, which #{platform} has no use for" if sources.any?

    { "platform" => expected, "extensions" => "none", **verify_java_extensions(files) }
  end

  # CRuby compiles the C sources on install. TruffleRuby JVM loads the bundled JAR.
  def verify_source(gem_file)
    spec     = spec(gem_file)
    files    = files(gem_file)
    binaries = files.keys.grep(BINARY) - JavaExtension::JARS

    raise Error, "declares no extension, so it would install without compiling" if spec.extensions.empty?
    raise Error, "ships prebuilt #{binaries.join(", ")}, which belongs in a platform gem" if binaries.any?

    { "platform" => "ruby", "extensions" => spec.extensions.join(", "),
      **verify_java_extensions(files) }
  end

  private

  def verify_java_extensions(files)
    JavaExtension::JARS.to_h do |path|
      classes = path == JavaExtension::JAR ? JavaExtension::CLASSES : JavaExtension::SCHEDULER_CLASSES
      begin
        [path, JavaExtension.validate(files[path], expected_classes: classes)]
      rescue RuntimeError => e
        raise Error, "#{path}: #{e.message}"
      end
    end
  end

  def spec(gem_file)
    Gem::Package.new(gem_file).spec
  end

  # Every file in the gem, as raw bytes, keyed by the path it installs to.
  def files(gem_file)
    files = {}

    File.open(gem_file, "rb") do |file|
      Gem::Package::TarReader.new(file) do |gem|
        gem.seek("data.tar.gz") do |data|
          Zlib::GzipReader.wrap(data) do |unzipped|
            Gem::Package::TarReader.new(unzipped) { |entry| entry.each { files[it.full_name] = it.read } }
            # Tar ends before gzip; consume the padding and validate the gzip footer before closing.
            unzipped.read(16 * 1024) until unzipped.eof?
          end
        end
      end
    end

    files
  end

  def describe(content)
    return "nothing" if content.nil?
    return describe_elf(content) if content.start_with?("\x7fELF".b)
    return describe_pe(content) if content.start_with?("MZ".b)
    return describe_mach_o(content) if MACH_O_MAGICS.key?(word(content, 0))
    UNKNOWN
  end

  def describe_elf(content)
    bits = content.getbyte(4) == 2 ? 64 : 32
    machine = ELF_MACHINES[content[18, 2].unpack1(content.getbyte(5) == 2 ? "n" : "v")] || "unknown"
    libc =
      if content.include?("libc.so.6\0".b) || content.include?("GLIBC_".b)
        "GNU libc"
      elsif content.include?("libc.so\0".b)
        "musl libc"
      else
        "unknown libc"
      end
    "ELF #{bits}-bit #{machine} #{libc}"
  end

  def describe_pe(content)
    coff = word(content, 0x3c)
    return UNKNOWN unless coff && content[coff, 4] == "PE\0\0".b

    machine = PE_MACHINES[content[coff + 4, 2].unpack1("v")]
    machine ? "PE #{machine == "i386" ? 32 : 64}-bit #{machine}" : UNKNOWN
  end

  def describe_mach_o(content)
    "Mach-O #{MACH_O_MAGICS[word(content, 0)]}-bit #{MACH_O_CPUS[word(content, 4)] || "unknown"}"
  end

  def word(content, offset)
    content[offset, 4]&.unpack1("V")
  end
end
