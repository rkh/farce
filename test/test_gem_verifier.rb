# frozen_string_literal: true

return if RUBY_ENGINE != "ruby"

require_relative "setup"
require_relative "../rakelib/gem_verifier"

require "rubygems/package"
require "tmpdir"

class TestGemVerifier < Test
  ABIS  = ["4.0.2", "3.4.9"].freeze
  NAMES = %w[rbtree rebind].freeze

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
    gem_file = gem_for("arm-linux-gnu", arm_binaries.except("lib/farce/engine/ruby/3.4/rbtree.so"))

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "arm-linux-gnu") }

    assert_includes error.message, "lib/farce/engine/ruby/3.4/rbtree.so"
    assert_includes error.message, "found nothing"
  end

  def test_rejects_gem_shipping_a_binary_it_was_not_supposed_to
    gem_file = gem_for("arm-linux-gnu", arm_binaries.merge(
      "lib/farce/engine/ruby/3.3/rbtree.so" => elf(bits: 32, machine: 0x28),
    ))

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "arm-linux-gnu") }

    assert_includes error.message, "lib/farce/engine/ruby/3.3/rbtree.so"
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
    gem_file = gem_for("arm-linux-gnu", arm_binaries, extensions: ["ext/rbtree/extconf.rb"])

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "arm-linux-gnu") }

    assert_includes error.message, "extension"
  end

  def test_rejects_gem_whose_required_ruby_version_excludes_a_shipped_abi
    gem_file = gem_for("arm-linux-gnu", arm_binaries, required_ruby_version: [">= 4.0", "< 4.1.dev"])

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "arm-linux-gnu") }

    assert_includes error.message, "3.4"
    assert_includes error.message, ">= 4.0"
  end

  # JRuby ships the pure-Ruby implementation, under a platform that is not the build target's name.
  def test_maps_the_jruby_build_target_to_the_java_gem_platform
    assert_equal "java", GemVerifier.gem_platform("jruby")
    assert_equal "arm-linux-gnu", GemVerifier.gem_platform("arm-linux-gnu")
    assert_equal "arm-linux-musl", GemVerifier.gem_platform("arm-linux-musl")
  end

  def test_knows_how_to_verify_every_platform_including_jruby
    assert_includes GemVerifier.targets, "jruby"
    assert_empty GemVerifier::SIGNATURES.keys - GemVerifier.targets
  end

  def test_accepts_java_gem_that_ships_only_ruby
    gem_file = gem_for("java", { "lib/farce/engine/jruby.rb" => "# ruby\n" })

    verify(gem_file, "jruby")
  end

  def test_rejects_java_gem_shipping_a_compiled_binary
    gem_file = gem_for("java", {
      "lib/farce/engine/jruby.rb"           => "# ruby\n",
      "lib/farce/engine/ruby/4.0/rbtree.so" => elf(bits: 64, machine: 0xb7),
    })

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

    assert_includes error.message, "lib/farce/engine/ruby/4.0/rbtree.so"
  end

  def test_rejects_java_gem_that_would_compile_on_install
    gem_file = gem_for("java", { "lib/farce/engine/jruby.rb" => "# ruby\n" },
      extensions: ["ext/rbtree/extconf.rb"])

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

    assert_includes error.message, "extension"
  end

  def test_rejects_java_gem_shipping_extension_sources
    gem_file = gem_for("java", {
      "lib/farce/engine/jruby.rb" => "# ruby\n",
      "ext/rbtree/rbtree.c"       => "int rbtree;\n",
    })

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

    assert_includes error.message, "ext/rbtree/rbtree.c"
  end

  def test_rejects_java_gem_that_is_not_built_for_java
    gem_file = gem_for("arm-linux-gnu", { "lib/farce/engine/jruby.rb" => "# ruby\n" })

    error = assert_raises(GemVerifier::Error) { verify(gem_file, "jruby") }

    assert_includes error.message, "platform"
    assert_includes error.message, "java"
  end

  def test_accepts_source_gem_that_compiles_on_install
    gem_file = gem_for(nil, {}, extensions: ["ext/rbtree/extconf.rb", "ext/rebind/extconf.rb"],
      required_ruby_version: [">= 3.4", "< 4.2"])

    verify(gem_file, nil)
  end

  def test_rejects_source_gem_shipping_a_prebuilt_binary
    gem_file = gem_for(nil, { "lib/farce/engine/ruby/4.0/rbtree.so" => elf(bits: 32, machine: 0x28) },
      extensions: ["ext/rbtree/extconf.rb"], required_ruby_version: [">= 3.4", "< 4.2"])

    error = assert_raises(GemVerifier::Error) { verify(gem_file, nil) }

    assert_includes error.message, "lib/farce/engine/ruby/4.0/rbtree.so"
  end

  def test_rejects_source_gem_that_would_not_compile_on_install
    gem_file = gem_for(nil, {}, required_ruby_version: [">= 3.4", "< 4.2"])

    error = assert_raises(GemVerifier::Error) { verify(gem_file, nil) }

    assert_includes error.message, "extension"
  end

  private

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
