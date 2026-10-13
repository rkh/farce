# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module ReleaseNotes
  # Keep the release heading and promote headings by two levels for GitHub.
  # Fenced examples may contain headings and must remain unchanged.
  def self.extract(changelog, version)
    notes = []
    collecting = false
    fence = nil

    changelog.each_line do |line|
      if fence
        fence = nil if line.match?(/\A {0,3}#{Regexp.escape(fence[0])}{#{fence.length},}[ \t]*\r?\n?\z/)
      elsif fence = line[/\A {0,3}(`{3,}|~{3,})/, 1]
        # The opening fence is part of the example too.
      else
        heading = line.match(/\A {0,3}(\#{1,6})[ \t]+(.*?)[ \t]*\r?\n?\z/)
        break if collecting && heading && heading[1].length <= 3

        if heading && heading[1] == "###" && heading[2].match?(/\AFarce #{Regexp.escape(version)}(?:[ \t]|\z)/)
          collecting = true
        end

        line = line.sub(/\A( {0,3})\#{3}/, '\1#') if collecting && heading
      end
      notes << line if collecting
    end

    raise "CHANGELOG.md has no section for Farce #{version}" unless collecting

    "#{notes.join.strip}\n"
  end
end
