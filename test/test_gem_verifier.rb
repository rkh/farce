# frozen_string_literal: true

return if RUBY_ENGINE != "ruby"

require_relative "setup"
require_relative "../rakelib/gem_verifier"

require "rubygems/package"
require "tmpdir"

class TestGemVerifier < Test
  ABIS       = ["4.0.2", "3.4.9"].freeze
  NAMES      = %w[containers rebind].freeze
  EXTENSIONS = NAMES.map { "ext/#{it}/extconf.rb" }.freeze

  def test_verifies_every_extension_in_the_source_gem
    spec = Gem::Specification.load(File.expand_path("../farce.gemspec", __dir__))
    unexpected_sources = spec.files.grep(%r{\Aext/}).reject do |path|
      path == "ext/ext_helper.rb" || (NAMES + ["java"]).include?(path.split("/")[1])
    end

    assert_equal EXTENSIONS, spec.extensions
    assert_equal ["MIT", "LicenseRef-Kazlib-1.20"], spec.licenses
    assert_includes spec.files, "ext/containers/dict.c"
    assert_includes spec.files, "ext/containers/dict.h"
    assert_includes spec.files, "ext/containers/priority_queue.c"
    assert_includes spec.files, "ext/containers/tree_map.c"
    assert_includes spec.files, "ext/java/org/farce/PriorityKey.java"
    assert_includes spec.files, "ext/java/org/farce/PriorityQueue.java"
    assert_includes spec.files, "ext/java/org/farce/QueueSignal.java"
    assert_includes spec.files, JavaExtension::JAR
    assert_empty unexpected_sources
  end

  def test_java_gem_declares_only_the_license_for_the_code_it_ships
    root = File.expand_path("..", __dir__)
    spec = Dir.chdir(root) { Gem::Specification.load("farce-java.gemspec") }

    assert_equal ["MIT"], spec.licenses
    assert_includes spec.files, JavaExtension::JAR
    assert_empty spec.files.grep(%r{\Aext/})
  end

  def test_accepts_gem_whose_binaries_all_match_the_target_platform
    gem_file = gem_for("arm-linux-gnu", arm_binaries)

    verify(gem_file, "arm-linux-gnu")
  end

  def test_accepts_musl_gem_whose_binaries_match_the_target_architecture
    gem_file = gem_for("arm-linux-musl", arm_binaries(libc: :musl))

    verify(gem_file, "arm-linux-musl")
  end

  # The bug this verifier exists to catch: a cross build that picked up a host binary.
  def test_rejects_gem_whose_binary_is_built_for_another_architecture
    gem_file = gem_for("arm-linux-gnu", arm_binaries.merge(
      "lib/farce/engine/ruby/4.0/rebind.so" => elf(bits: 64, machine: 0xb7),
    ))

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "arm-linux-gnu") }

    assert_includes error.message, "lib/farce/engine/ruby/4.0/rebind.so"
    assert_includes error.message, "ELF 32-bit arm GNU libc"
    assert_includes error.message, "ELF 64-bit aarch64 GNU libc"
  end

  def test_accepts_windows_gem_carrying_pe_binaries
    gem_file = gem_for("x64-mingw-ucrt", ext_paths("so").to_h { [it, pe(machine: 0x8664)] })

    verify(gem_file, "x64-mingw-ucrt")
  end

  def test_accepts_darwin_gem_carrying_mach_o_bundles
    gem_file = gem_for("arm64-darwin", ext_paths("bundle").to_h { [it, mach_o(cputype: 0x0100000c)] })

    verify(gem_file, "arm64-darwin")
  end

  def test_rejects_windows_gem_whose_binary_is_built_for_another_architecture
    gem_file = gem_for("aarch64-mingw-ucrt", ext_paths("so").to_h { [it, pe(machine: 0x8664)] })

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "aarch64-mingw-ucrt") }

    assert_includes error.message, "expected PE 64-bit aarch64, found PE 64-bit x86_64"
  end

  def test_rejects_gem_missing_the_binary_for_one_extension
    path = "lib/farce/engine/ruby/3.4/containers.so"
    gem_file = gem_for("arm-linux-gnu", arm_binaries.except(path))

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "arm-linux-gnu") }

    assert_includes error.message, path
    assert_includes error.message, "found nothing"
  end

  def test_rejects_gem_shipping_a_binary_it_was_not_supposed_to
    gem_file = gem_for("arm-linux-gnu", arm_binaries.merge(
      "lib/farce/engine/ruby/3.3/containers.so" => elf(bits: 32, machine: 0x28),
    ))

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "arm-linux-gnu") }

    assert_includes error.message, "lib/farce/engine/ruby/3.3/containers.so"
  end

  def test_rejects_gem_whose_platform_does_not_match_the_build_target
    gem_file = gem_for("aarch64-linux-gnu", arm_binaries)

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "arm-linux-gnu") }

    assert_includes error.message, "platform"
    assert_includes error.message, "aarch64-linux-gnu"
  end

  def test_rejects_gnu_binary_packaged_for_musl
    gem_file = gem_for("arm-linux-musl", arm_binaries)

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "arm-linux-musl") }

    assert_includes error.message, "expected ELF 32-bit arm musl libc"
    assert_includes error.message, "found ELF 32-bit arm GNU libc"
  end

  def test_rejects_precompiled_gem_that_would_still_compile_on_install
    gem_file = gem_for("arm-linux-gnu", arm_binaries, extensions: [EXTENSIONS.first])

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "arm-linux-gnu") }

    assert_includes error.message, "extension"
  end

  def test_rejects_gem_whose_required_ruby_version_excludes_a_shipped_abi
    gem_file = gem_for("arm-linux-gnu", arm_binaries, required_ruby_version: [">= 4.0", "< 4.1.dev"])

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "arm-linux-gnu") }

    assert_includes error.message, "3.4"
    assert_includes error.message, ">= 4.0"
  end

  # JRuby's declared gem platform differs from its build target name.
  def test_maps_the_jruby_build_target_to_the_java_gem_platform
    assert_equal "java", GemVerifier.gem_platform("jruby")
    assert_equal "arm-linux-gnu", GemVerifier.gem_platform("arm-linux-gnu")
    assert_equal "arm-linux-musl", GemVerifier.gem_platform("arm-linux-musl")
  end

  def test_knows_how_to_verify_every_platform_including_jruby
    assert_includes GemVerifier.targets, "jruby"
    assert_empty GemVerifier::SIGNATURES.keys - GemVerifier.targets
  end

  def test_accepts_java_gem_with_portable_bytecode
    gem_file = gem_for("java", { "lib/farce/engine/jruby.rb" => "# ruby\n" })

    verify(gem_file, "jruby")
  end

  def test_rejects_java_gem_shipping_a_native_binary
    gem_file = gem_for("java", {
      "lib/farce/engine/jruby.rb"               => "# ruby\n",
      "lib/farce/engine/ruby/4.0/containers.so" => elf(bits: 64, machine: 0xb7),
    })

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

    assert_includes error.message, "lib/farce/engine/ruby/4.0/containers.so"
  end

  def test_rejects_java_gem_that_would_compile_on_install
    gem_file = gem_for("java", { "lib/farce/engine/jruby.rb" => "# ruby\n" },
      extensions: [EXTENSIONS.first])

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

    assert_includes error.message, "extension"
  end

  def test_rejects_java_gem_shipping_extension_sources
    gem_file = gem_for("java", {
      "lib/farce/engine/jruby.rb"       => "# ruby\n",
      "ext/containers/priority_queue.c" => "int priority_queue;\n",
    })

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

    assert_includes error.message, "ext/containers/priority_queue.c"
  end

  def test_rejects_java_gem_that_is_not_built_for_java
    gem_file = gem_for("arm-linux-gnu", { "lib/farce/engine/jruby.rb" => "# ruby\n" })

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

    assert_includes error.message, "platform"
    assert_includes error.message, "java"
  end

  def test_accepts_source_gem_that_compiles_on_install
    gem_file = gem_for(nil, {}, extensions: EXTENSIONS,
      required_ruby_version: [">= 3.4", "< 4.2"])

    verify(gem_file, nil)
  end

  def test_rejects_source_gem_shipping_a_prebuilt_binary
    path = "lib/farce/engine/ruby/4.0/containers.so"
    gem_file = gem_for(nil, { path => elf(bits: 32, machine: 0x28) },
      extensions: EXTENSIONS, required_ruby_version: [">= 3.4", "< 4.2"])

    error = assert_raises(GemVerifier::Error) { verify(gem_file, nil) }

    assert_includes error.message, path
  end

  def test_rejects_source_gem_that_would_not_compile_on_install
    gem_file = gem_for(nil, {}, required_ruby_version: [">= 3.4", "< 4.2"])

    error = assert_raises(GemVerifier::Error) { verify(gem_file, nil) }

    assert_includes error.message, "extension"
  end

  def test_rejects_missing_java_extension_in_source_and_java_gems
    [nil, "java"].each do |platform|
      gem_file = gem_for(platform, { JavaExtension::JAR => nil }, extensions: platform ? [] : EXTENSIONS)
      error = assert_raises(GemVerifier::Error) { verify(gem_file, platform && "jruby") }

      assert_includes error.message, "missing Java extension"
    end
  end

  def test_rejects_corrupt_java_archive
    gem_file = gem_for("java", { JavaExtension::JAR => "not a jar" })
    error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

    assert_includes error.message, JavaExtension::JAR
  end

  def test_rejects_truncated_java_archive_headers
    gem_file = gem_for("java", { JavaExtension::JAR => "PK\x03\x04\x00" })
    error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

    assert_includes error.message, "truncated Java archive"
  end

  def test_rejects_java_archives_outside_the_expected_extension
    gem_file = gem_for(nil, { "lib/unexpected.jar" => "PK\x03\x04" }, extensions: EXTENSIONS)
    error = assert_raises(GemVerifier::Error) { verify(gem_file, nil) }

    assert_includes error.message, "lib/unexpected.jar"
  end

  def test_rejects_java_bytecode_requiring_a_newer_vm_or_preview_features
    [[62, 0], [61, 65535]].each do |version, minor|
      gem_file = gem_for("java", { JavaExtension::JAR => java_archive(version:, minor:) })
      error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

      assert_includes error.message, "Java 17 bytecode without preview features"
    end
  end

  def test_rejects_corrupt_java_class_contents
    archive = java_archive(version: 61)
    archive.setbyte(archive.index("\xCA\xFE\xBA\xBE".b), 0)
    gem_file = gem_for("java", { JavaExtension::JAR => archive })
    error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

    assert_includes error.message, "corrupt Java archive entry"
  end

  private

  def java_archive(version:, minor: 0)
    name = JavaExtension::CLASSES.first
    content = "\xCA\xFE\xBA\xBE".b + [minor, version].pack("n2")
    header = [20, 0, 0, 0, 0, Zlib.crc32(content), content.size, content.size, name.size, 0].pack("v5V3v2")
    ["PK\x03\x04", header, name, content, "PK\x01\x02"].join.b
  end

  def verify(gem_file, platform)
    GemVerifier.verify(gem_file, platform:, abis: ABIS, names: NAMES)
  end

  def ext_paths(dlext)
    NAMES.product(ABIS).map { "lib/farce/engine/ruby/#{it.last[/^\d+\.\d+/]}/#{it.first}.#{dlext}" }
  end

  def arm_binaries(libc: :gnu)
    ext_paths("so").to_h { [it, elf(bits: 32, machine: 0x28, libc:)] }
  end

  def gem_for(platform, files, extensions: [], required_ruby_version: [">= 3.4", "< 4.1.dev"])
    jar = File.expand_path("../#{JavaExtension::JAR}", __dir__)
    files = { JavaExtension::JAR => File.binread(jar) }.merge(files).compact
    dir = Dir.mktmpdir("test_gem_verifier")
    (@tmpdirs ||= []) << dir

    Dir.chdir(dir) do
      # rubygems folds extensions into spec.files, so those have to exist on disk as well
      (files.keys + extensions).each do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, files[path] || "# stub\n")
      end

      spec = Gem::Specification.new("farce", "0.1.0") do |s|
        s.summary               = "gem verifier test fixture"
        s.authors               = ["test"]
        s.files                 = files.keys
        s.platform              = platform if platform
        s.extensions            = extensions
        s.required_ruby_version = required_ruby_version
      end

      built = Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) { Gem::Package.build(spec, true) }
      File.join(dir, built)
    end
  end

  def teardown
    @tmpdirs&.each { FileUtils.rm_rf(it) }
  end

  # e_ident (16 bytes), e_type, e_machine
  def elf(bits:, machine:, libc: :gnu)
    marker = { gnu: "libc.so.6\0GLIBC_2.2.5\0", musl: "libc.so\0" }.fetch(libc)
    "\x7fELF".b + [bits == 64 ? 2 : 1, 1, 1, 0].pack("C4") + ("\0" * 8) + [3, machine].pack("v2") + marker
  end

  # DOS stub with e_lfanew at 0x3c pointing at the COFF header
  def pe(machine:)
    stub = "MZ".b + ("\0" * 0x3a) + [0x40].pack("V")
    stub + "PE\0\0".b + [machine].pack("v")
  end

  # mach_header_64: magic, cputype, cpusubtype, filetype (8 == MH_BUNDLE)
  def mach_o(cputype:)
    [0xfeedfacf, cputype, 0, 8].pack("V4")
  end
end
