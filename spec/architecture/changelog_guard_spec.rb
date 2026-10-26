# frozen_string_literal: true

require 'rails_helper'

# What: the shape of CHANGELOG.md.
# Why:  script/release reads and writes it (lib/lalabase/release.rb), and a
#       self-hoster reads it before every update. A heading in another shape
#       would be invisible to the script: `publish` would find no notes, and
#       `prepare` would put the next release in the wrong place.
#
# The rules are Lalabase::Release.problems, which publish asks too (a pull
# request touching only CHANGELOG.md skips guards.yml). Until the first release
# the file has no release to check, so the rules also run against a broken
# sample they must catch: green here is not green in a vacuum.
RSpec.describe 'CHANGELOG.md', type: :model do
  it 'has the shape script/release relies on' do
    expect(Lalabase::Release.problems(Rails.root.join('CHANGELOG.md').read)).to eq([])
  end

  it 'would catch every broken shape (self-test on a sample)' do
    broken = <<~MD
      # Changelog

      ## [2026.10.0] - 2026-10-30

      ### Fixed

      - x

      ## [Unreleased]

      ## Notes

      ## [2026.01.0] - 2026-02-30

      ### Upgrade notes

      - None.

      ## [2026.10.0] - 2026-10-30

      ## [2026.12.0] - 2026-12-01

      ### Unsorted (move or delete before publishing)

      - a title without a type (#9)

      ### Upgrade notes

      - None.
    MD

    expect(Lalabase::Release.problems(broken)).to include(
      'Unreleased is not the first section', 'not a release heading: ## [Unreleased]',
      'not a release heading: ## Notes', 'not a version: 2026.01.0', 'a version appears twice',
      'not a date: 2026-02-30', 'no upgrade notes: 2026.10.0', 'releases are not newest first',
      'unsorted entries left: 2026.12.0'
    )
  end

  # compose.yml of a tag pulls the image built from that tag. prepare writes
  # both files, publish holds the version against compose.yml; a hand edit of
  # one of them shows here, before a release is cut from it.
  it 'goes with a compose.yml that pulls the image of the newest release' do
    newest = Rails.root.join('CHANGELOG.md').read.match(Lalabase::Release::VERSION_HEADING)[:version]

    expect(Lalabase::Release.compose_version(Rails.root.join('compose.yml').read)).to eq(newest)
  end

  it 'accepts a release in the right shape' do
    good = "# Changelog\n\n## [Unreleased]\n\n## [2026.11.0] - 2026-11-20\n\n### Upgrade notes\n\n- None.\n\n" \
           "## [2026.10.0] - 2026-10-30\n\n### Upgrade notes\n\n- None.\n"
    expect(Lalabase::Release.problems(good)).to eq([])
  end
end
