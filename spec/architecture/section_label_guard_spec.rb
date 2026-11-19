# frozen_string_literal: true

require 'rails_helper'

# Guard: the label of a section has one look, and one owner, the class
# .section-label (application.tailwind.css; F51 of the Belegungstabelle,
# doc/belegungstabelle_oberflaeche.md): small mono capitals, semibold,
# tracking 0.14em. It names a block of a page (the head of a widget, the
# summary in the ticket timeline) or a group of the navigation ("PROJEKTE").
#
# Until 2026-11-19 every place wrote that look out by hand: seven class lists
# and one class of its own (the people card). The widget heads still wore an
# older look with a "//" in front, left over from an earlier design.
#
# What this holds:
#   A. The mark of the recipe, tracking-[0.14em], is written nowhere but in
#      .section-label: not in a template, a component, a helper, a script or
#      a stylesheet. The copies per file stand in LEGACY, which may only
#      shrink: a count too high or too low is red.
#   B. .section-label carries the type and nothing else. The colour stays
#      with the place (ink over content, the muted tone over a group of
#      links), so a colour in the class would be wrong for half its users.
#
# Not read: app/views/admin/ (its own style guide, decided 2026-06-01),
# app/views/style_guide/ (it shows samples) and app/assets/builds/ (built).
# Not seen: a label that copies the look with another spacing
# (tracking-widest), or a class list put together at run time. It is a
# tripwire, not a proof.
#
# It runs through the directory entry spec/architecture/ of the CI guard list.
module SectionLabels
  ROOTS = %w[app/views app/components app/helpers app/javascript app/assets/stylesheets].freeze
  SKIPPED = %w[app/views/admin/ app/views/style_guide/ app/assets/builds/].freeze
  OWNER = 'app/assets/stylesheets/application.tailwind.css'
  MARK = 'tracking-[0.14em]'
  RECIPE = '.section-label { @apply font-mono text-[11px] font-semibold uppercase tracking-[0.14em]; }'

  # Written by hand, by decision or not yet moved. Only shrinks.
  LEGACY = {
    # The title of the organisation picker: a page title in the label's
    # shape, but text-sm. Moves when the picker gets its own row.
    'app/views/organisations/select.html.erb' => 1
  }.freeze

  module_function

  def files
    ROOTS.flat_map { |root| Dir.glob(Rails.root.join(root, '**', '*').to_s) }
         .select { |path| File.file?(path) }
         .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
         .reject { |path| SKIPPED.any? { |prefix| path.start_with?(prefix) } }
  end

  # Files that write the mark, with the number of times, the owner's own
  # definition left out.
  def copies
    files.each_with_object({}) do |path, found|
      lines = File.readlines(Rails.root.join(path), encoding: 'UTF-8')
      lines = lines.reject { |line| line.include?('.section-label {') } if path == OWNER
      count = lines.sum { |line| line.scan(MARK).size }
      found[path] = count if count.positive?
    end
  end
end

RSpec.describe 'Section label guard' do
  it 'writes the recipe of the section label nowhere but in .section-label (A)' do
    found = SectionLabels.copies
    drift = (found.keys | SectionLabels::LEGACY.keys).filter_map do |path|
      have = found.fetch(path, 0)
      allowed = SectionLabels::LEGACY.fetch(path, 0)
      "#{path}: #{have} (allowed #{allowed})" unless have == allowed
    end

    expect(drift).to be_empty, <<~MSG
      The look of a section label is written by hand outside .section-label:
        #{drift.join("\n  ")}
      Use the class `section-label` and put the colour beside it. A file that
      moved: lower or remove its entry in LEGACY.
    MSG
  end

  it 'finds the copies it is looking for, so a green run is no empty search' do
    expect(SectionLabels.files).to include('app/views/organisations/select.html.erb', SectionLabels::OWNER)
    expect(SectionLabels.copies).to include('app/views/organisations/select.html.erb' => 1)
  end

  it 'keeps the type, and nothing but the type, in .section-label (B)' do
    css = Rails.root.join(SectionLabels::OWNER).read

    expect(css.lines.map(&:strip)).to include(SectionLabels::RECIPE)
  end
end
