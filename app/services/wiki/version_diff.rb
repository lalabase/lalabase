# frozen_string_literal: true

require 'diff/lcs'

module Wiki
  # Line-based diff between two NoteVersions, computed on the derived markdown_body — the
  # GFM projection is exactly the stable, line-oriented text the diff is meant for (the raw
  # ActionText HTML would diff as noisy one-liners). Output is a flat list of rows ready for
  # a UNIFIED rendering (one column, +/- lines).
  #
  #   old_version may be nil (the v0 baseline has no predecessor) → the whole new content
  #   reads as "added", which is the right story for the first version.
  class VersionDiff
    # type: :unchanged | :added | :removed
    Line = Struct.new(:type, :text, keyword_init: true)

    def self.call(old_version, new_version)
      new(old_version, new_version).call
    end

    def initialize(old_version, new_version)
      @old_lines = old_version&.markdown_body.to_s.split("\n")
      @new_lines = new_version&.markdown_body.to_s.split("\n")
    end

    def call
      Diff::LCS.sdiff(@old_lines, @new_lines).flat_map do |change|
        case change.action
        when '=' then [Line.new(type: :unchanged, text: change.new_element)]
        when '+' then [Line.new(type: :added,     text: change.new_element)]
        when '-' then [Line.new(type: :removed,   text: change.old_element)]
        # '!' = a line replaced by another: show both, removed then added.
        when '!' then [Line.new(type: :removed, text: change.old_element),
                       Line.new(type: :added,   text: change.new_element)]
        end
      end
    end
  end
end
