# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/lalabase/release'

# What: Lalabase::Release, the rules script/release follows.
# Why:  A self-hoster reads the version to know how old an install is, and the
#       CHANGELOG to know what an update asks of them. A wrong next number or a
#       hand-written line lost on prepare would mislead exactly that reader.
RSpec.describe Lalabase::Release do
  describe '.version?' do
    it 'takes YEAR.MONTH.PATCH with the month unpadded' do
      expect(%w[2026.11.0 2027.1.0 2026.12.14].map { |v| described_class.version?(v) }).to all(be(true))
    end

    it 'refuses a padded month, a thirteenth month and other tags' do
      expect(%w[2026.01.0 2026.13.0 2026.11 v2026.11.0 messung-0 backup/x].map { |v| described_class.version?(v) })
        .to all(be(false))
    end
  end

  describe '.latest' do
    it 'compares numerically and ignores other tags' do
      expect(described_class.latest(%w[2026.9.0 2026.11.0 2026.10.3 messung-0 9999-backup])).to eq('2026.11.0')
    end
  end

  describe '.next_version' do
    let(:today) { Date.new(2026, 11, 20) }

    it 'starts a month at .0' do
      expect(described_class.next_version(%w[2026.10.0 2026.10.1], today: today)).to eq('2026.11.0')
    end

    it 'counts up within a month, from the highest patch' do
      expect(described_class.next_version(%w[2026.11.0 2026.11.1], today: today)).to eq('2026.11.2')
      expect(described_class.next_version(%w[2026.11.0 2026.11.2], today: today)).to eq('2026.11.3')
    end

    it 'writes January without a leading zero' do
      expect(described_class.next_version([], today: Date.new(2027, 1, 3))).to eq('2027.1.0')
    end
  end

  describe '.draft' do
    let(:prs) do
      [{ number: 1, title: 'feat(tickets): relations' }, { number: 2, title: 'fix: unread count' },
       { number: 3, title: 'security(auth): lockout' }, { number: 4, title: 'chore: rename' },
       { number: 6, title: 'perf(search): faster' },
       { number: 5, title: 'A title without a type' }]
    end

    it 'sorts pull requests into sections by their type and lists the rest visibly as unsorted' do
      block = described_class.draft('2026.11.0', '2026-11-20', prs)

      expect(block).to start_with("## [2026.11.0] - 2026-11-20\n")
      expect(block).to include("### Added\n\n- relations (#1)", "### Fixed\n\n- unread count (#2)",
                               "### Security\n\n- lockout (#3)", "### Changed\n\n- faster (#6)")
      expect(block).to include("#{described_class::UNSORTED}\n\n- rename (#4)\n- A title without a type (#5)")
      expect(block.index(described_class::UNSORTED)).to be < block.index('### Upgrade notes')
    end

    it 'turns a breaking change (feat!:) into an upgrade note' do
      block = described_class.draft('2026.11.0', '2026-11-20', [{ number: 7, title: 'feat(api)!: drop v0' }])

      expect(block).to include("### Upgrade notes\n\n- Breaking change, read before updating: drop v0 (#7)")
    end

    it 'always has upgrade notes, "None." when there is nothing to do' do
      expect(described_class.draft('2026.11.0', '2026-11-20', [])).to include("### Upgrade notes\n\n- None.")
      expect(described_class.draft('2026.11.0', '2026-11-20', [], upgrade_hints: ['Run X.']))
        .to include("### Upgrade notes\n\n- Run X.")
    end

    it 'calls the first release that, whatever was merged before' do
      block = described_class.draft('2026.11.0', '2026-11-20', prs, first: true)

      expect(block).to include("- #{described_class::FIRST_RELEASE}")
      expect(block).not_to include('relations')
    end
  end

  describe '.pull_request_numbers' do
    it 'reads the numbers off the merge commits of main' do
      subjects = ['Merge pull request #966 from gboyke/feat/mcp', 'Merge branch main into x',
                  'Merge pull request #12 from someone/fix']

      expect(described_class.pull_request_numbers(subjects)).to eq([966, 12])
    end

    it 'reads squash merges, "title (#N)", too' do
      expect(described_class.pull_request_numbers(['fix: the count (#41)', 'wip', 'Merge pull request #3 from x/y']))
        .to eq([41, 3])
    end
  end

  describe '.problems' do
    it 'finds a repeated heading and "None." beside real upgrade notes in a release' do
      text = "# Changelog\n\n## [Unreleased]\n\n## [2026.11.0] - 2026-11-20\n\n### Fixed\n\n- a\n\n### Fixed\n\n- b\n\n" \
             "### Upgrade notes\n\n- Set FOO.\n- None.\n"

      expect(described_class.problems(text)).to include('2026.11.0 has ### Fixed twice',
                                                        '2026.11.0: "None." beside real upgrade notes')
    end
  end

  describe '.drafted_from and .notes' do
    it 'reads the commit a draft was made from, and gives the notes without that mark' do
      section = "<!-- drafted from #{'a' * 40} -->\n\n### Fixed\n\n- x"

      expect(described_class.drafted_from(section)).to eq('a' * 40)
      expect(described_class.notes(section)).to eq("### Fixed\n\n- x")
    end
  end

  describe '.insert and .section' do
    let(:changelog) { "# Changelog\n\nIntro.\n\n## [Unreleased]\n\n## [2026.10.0] - 2026-10-30\n\n### Fixed\n\n- old\n" }
    let(:block) { described_class.draft('2026.11.0', '2026-11-20', [{ number: 9, title: 'feat: new' }]) }

    it 'puts the release under Unreleased, above the older ones, and leaves Unreleased empty' do
      result = described_class.insert(changelog, block)

      expect(result).to include("## [Unreleased]\n\n## [2026.11.0] - 2026-11-20")
      expect(result.index('## [2026.11.0]')).to be < result.index('## [2026.10.0]')
      expect(described_class.section(result, '2026.10.0')).to eq("### Fixed\n\n- old")
    end

    it 'moves a line written under Unreleased into the release instead of dropping it' do
      result = described_class.insert(changelog.sub("## [Unreleased]\n", "## [Unreleased]\n\n- by hand\n"), block)

      expect(described_class.section(result, '2026.11.0')).to include('- by hand', '- new (#9)')
      expect(result).to include("## [Unreleased]\n\n## [2026.11.0]")
    end

    it 'finds Unreleased only as the heading, not as text or a deeper heading' do
      text = "# Changelog\n\nSee ## [Unreleased] below.\n\n### [Unreleased]\n\n## [Unreleased]\n"
      result = described_class.insert(text, block)

      expect(result).to include("## [Unreleased]\n\n## [2026.11.0]")
      expect(result).to include("See ## [Unreleased] below.\n\n### [Unreleased]\n\n## [Unreleased]")
    end

    it 'merges sections written under Unreleased into the release instead of repeating them' do
      unreleased = "## [Unreleased]\n\n### Upgrade notes\n\n- Set FOO.\n\n### Fixed\n\n- by hand\n"
      result = described_class.insert(changelog.sub("## [Unreleased]\n", unreleased), block)
      notes = described_class.section(result, '2026.11.0')

      expect(notes.scan('### Upgrade notes').size).to eq(1)
      expect(notes).to include("### Upgrade notes\n\n- Set FOO.").and include('- by hand')
      expect(notes).not_to include('- None.')
    end

    it 'returns the notes of one release, or nil when it has none' do
      result = described_class.insert(changelog, block)

      expect(described_class.section(result, '2026.11.0')).to start_with("### Added\n\n- new (#9)")
      expect(described_class.section(result, '2099.1.0')).to be_nil
    end
  end

  describe '.mentioned_numbers' do
    it 'reads the pull requests a section names as (#N), and nothing else' do
      expect(described_class.mentioned_numbers("- one (#5)\n- two (#12), see #7\n- one again (#5)")).to eq([5, 12])
    end
  end
end
