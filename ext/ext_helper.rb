# frozen_string_literal: true

module ExtHelper
  extend self

  def ext_path(ext_name = nil, engine: RUBY_ENGINE, version: RUBY_ENGINE_VERSION, lib: false)
    # Build explicitly because Ruby 4 freezes interpolated literals under
    # `frozen_string_literal`, while this path is assembled incrementally.
    dir = String.new
    dir << "lib/" if lib
    dir << "farce/engine/" << engine

    case RUBY_ENGINE
    when "ruby"        then dir << "/#{version[/^\d+\.\d+/]}"
    when "truffleruby" then dir << "/#{TruffleRuby.native? ? "native" : "graalvm"}/#{version}"
    end
    dir << "/#{File.basename(ext_name)}" if ext_name
    dir.freeze
  end
end
