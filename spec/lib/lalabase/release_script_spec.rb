# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# What: script/release end to end, in a throwaway repository with a bare
#       repository as origin and a stand-in for `gh`.
# Why:  The review of #968 found the script losing pull requests (a time
#       comparison across time zones, merges between prepare and publish) and
#       not being repeatable (prepare twice, publish after a half failure).
#       None of that is visible from lib/lalabase/release.rb alone.
RSpec.describe 'script/release' do
  let(:root) { File.expand_path('../../..', __dir__) }

  let(:fake_gh) do
    <<~SH
      #!/bin/sh
      state="$FAKE_GH_STATE"
      case "$1 $2" in
        "auth status") [ -f "$state/logged_out" ] && exit 1; exit 0 ;;
        "pr list") cat "$state/prs.json" ;;
        "pr view") printf '{"title":"viewed %s"}' "$3" ;;
        "release view") [ -f "$state/release-$3" ] ;;
        "release create")
          if [ -f "$state/fail_create" ]; then rm "$state/fail_create"; echo "boom" >&2; exit 1; fi
          cat > "$state/release-$3" ;;
        *) echo "unexpected gh $*" >&2; exit 2 ;;
      esac
    SH
  end

  around do |example|
    Dir.mktmpdir('release-script-') do |tmp|
      @tmp = tmp
      example.run
    end
  end

  def work = File.join(@tmp, 'work')
  def state = File.join(@tmp, 'gh')

  def git(*args, dir: work)
    out, status = Open3.capture2e('git', '-C', dir, '-c', 'user.email=t@example.com', '-c', 'user.name=t', *args)
    raise "git #{args.join(' ')}: #{out}" unless status.success?

    out
  end

  def release(*args)
    env = { 'PATH' => "#{File.join(@tmp, 'bin')}:#{ENV.fetch('PATH')}", 'FAKE_GH_STATE' => state }
    out, status = Open3.capture2e(env, 'ruby', File.join(work, 'script/release'), *args, chdir: work)
    [out, status.success?]
  end

  def merge_pull_request(number, title)
    git('switch', '-q', '-c', "pr-#{number}")
    File.write(File.join(work, "f#{number}.txt"), title)
    git('add', '-A')
    git('commit', '-q', '-m', title)
    git('switch', '-q', 'main')
    git('merge', '-q', '--no-ff', "pr-#{number}", '-m', "Merge pull request ##{number} from someone/pr-#{number}")
    git('push', '-q', 'origin', 'main')
    record_pull_request(number, title)
  end

  def record_pull_request(number, title)
    prs = JSON.parse(File.read(File.join(state, 'prs.json'))) << { 'number' => number, 'title' => title }
    File.write(File.join(state, 'prs.json'), JSON.generate(prs))
  end

  # A squash merge: one commit on main, "title (#N)", no merge commit.
  def squash_pull_request(number, title)
    File.write(File.join(work, "s#{number}.txt"), title)
    git('add', '-A')
    git('commit', '-q', '-m', "#{title} (##{number})")
    git('push', '-q', 'origin', 'main')
    record_pull_request(number, title)
  end

  # A pull request that only changes CHANGELOG.md (the release notes, or a line under Unreleased).
  def changelog_pull_request(number)
    git('switch', '-q', '-c', "pr-#{number}")
    yield File.join(work, 'CHANGELOG.md')
    git('commit', '-q', '-am', "changelog #{number}")
    git('switch', '-q', 'main')
    git('merge', '-q', '--no-ff', "pr-#{number}", '-m', "Merge pull request ##{number} from someone/pr-#{number}")
    git('push', '-q', 'origin', 'main')
  end

  def compose_with(version, restart: 'unless-stopped')
    "x-app: &app\n  image: ghcr.io/lalabase/lalabase:${LALABASE_VERSION:-#{version}}\n  restart: #{restart}\n"
  end

  def compose_file = File.join(work, 'compose.yml')

  # A pull request that writes the given files (path => content), merged.
  def pull_request_writing(number, title, files)
    git('switch', '-q', '-c', "pr-#{number}")
    files.each { |path, content| File.write(File.join(work, path), content) }
    git('commit', '-q', '-am', title)
    git('switch', '-q', 'main')
    git('merge', '-q', '--no-ff', "pr-#{number}", '-m', "Merge pull request ##{number} from someone/pr-#{number}")
    git('push', '-q', 'origin', 'main')
    record_pull_request(number, title)
  end

  before do
    FileUtils.mkdir_p([File.join(@tmp, 'bin'), state])
    File.write(File.join(@tmp, 'bin/gh'), fake_gh)
    File.chmod(0o755, File.join(@tmp, 'bin/gh'))
    File.write(File.join(state, 'prs.json'), '[]')
    git('init', '-q', '--bare', '-b', 'main', File.join(@tmp, 'origin.git'), dir: @tmp)
    git('clone', '-q', File.join(@tmp, 'origin.git'), work, dir: @tmp)
    # The CI runner has no git identity, and an annotated tag needs a tagger.
    git('config', 'user.name', 't')
    git('config', 'user.email', 't@example.com')
    FileUtils.mkdir_p([File.join(work, 'script'), File.join(work, 'lib/lalabase')])
    FileUtils.cp(File.join(root, 'script/release'), File.join(work, 'script/release'))
    FileUtils.cp(File.join(root, 'lib/lalabase/release.rb'), File.join(work, 'lib/lalabase/release.rb'))
    File.write(File.join(work, 'CHANGELOG.md'), "# Changelog\n\n## [Unreleased]\n")
    File.write(File.join(work, 'compose.yml'), compose_with('2026.9.0'))
    git('switch', '-q', '-c', 'main')
    git('add', '-A')
    git('commit', '-q', '-m', 'init')
    git('tag', '2026.9.0')
    git('push', '-q', 'origin', 'main', '2026.9.0')
  end

  # Merges right after the tag, whatever the clock says (finding 1).
  it 'drafts every pull request merged since the last release tag' do
    merge_pull_request(5, 'feat: one task')
    merge_pull_request(6, 'fix: the count')

    out, ok = release('draft')

    expect(ok).to be(true), out
    expect(out).to include('- one task (#5)', '- the count (#6)')
  end

  # Review 2, point 9: not every self-hoster runs the container.
  it 'tells about changed data backfills, also how to run them without Docker' do
    git('switch', '-q', '-c', 'pr-21')
    File.write(File.join(work, 'lib/lalabase/data_backfills.rb'), "# one more\n")
    git('add', '-A')
    git('commit', '-q', '-m', 'backfill')
    git('switch', '-q', 'main')
    git('merge', '-q', '--no-ff', 'pr-21', '-m', 'Merge pull request #21 from someone/pr-21')
    git('push', '-q', 'origin', 'main')
    record_pull_request(21, 'feat: a backfill')

    out, ok = release('draft')

    expect(ok).to be(true), out
    expect(out).to include('The data backfills changed', 'without Docker: `bin/rails lalabase:data_backfills`')
  end

  # Review 2, point 2c/2d: squash merges and stacked pull requests count too.
  it 'drafts squash merges and the inner pull request of a stack' do
    squash_pull_request(11, 'fix: squashed one')
    git('switch', '-q', '-c', 'outer')
    git('switch', '-q', '-c', 'inner')
    File.write(File.join(work, 'inner.txt'), 'x')
    git('add', '-A')
    git('commit', '-q', '-m', 'inner work')
    git('switch', '-q', 'outer')
    git('merge', '-q', '--no-ff', 'inner', '-m', 'Merge pull request #12 from someone/inner')
    git('switch', '-q', 'main')
    git('merge', '-q', '--no-ff', 'outer', '-m', 'Merge pull request #13 from someone/outer')
    git('push', '-q', 'origin', 'main')
    record_pull_request(12, 'feat: inner')
    record_pull_request(13, 'feat: outer')

    out, ok = release('draft')

    expect(ok).to be(true), out
    expect(out).to include('- squashed one (#11)', '- inner (#12)', '- outer (#13)')
  end

  it 'refuses to draft without the tags of origin' do
    git('remote', 'remove', 'origin')

    out, ok = release('prepare', '2026.10.0')

    expect(ok).to be(false)
    expect(out).to include('Could not fetch the tags of origin')
  end

  # Review 2, point 2b: merged while the notes pull request was still open.
  it 'stops when a pull request was merged while the notes were in review' do
    merge_pull_request(5, 'feat: one task')
    git('switch', '-q', '-c', 'release-notes')
    release('prepare', '2026.10.0')
    git('commit', '-q', '-am', 'release notes 2026.10.0')
    git('switch', '-q', 'main')
    merge_pull_request(8, 'fix: merged meanwhile')
    git('merge', '-q', '--no-ff', 'release-notes', '-m', 'Merge pull request #7 from someone/release-notes')
    git('push', '-q', 'origin', 'main')

    out, ok = release('publish', '2026.10.0')

    expect(ok).to be(false)
    expect(out).to include('not in the release notes: #8')
  end

  it 'refuses to prepare the same version twice' do
    merge_pull_request(5, 'feat: one task')
    expect(release('prepare', '2026.10.0').last).to be(true)

    out, ok = release('prepare', '2026.10.0')

    expect(ok).to be(false)
    expect(out).to include('do not prepare it twice')
    expect(File.read(File.join(work, 'CHANGELOG.md')).scan('## [2026.10.0]').size).to eq(1)
  end

  it 'refuses a version that is not newer than the last release' do
    out, ok = release('prepare', '2026.8.0')

    expect(ok).to be(false)
    expect(out).to include('not newer than the last release 2026.9.0')
  end

  # A checked-out tag pulls the image built from it: compose.yml of the tag
  # names its version, and prepare is what writes it.
  it 'writes the version into compose.yml on prepare' do
    merge_pull_request(5, 'feat: one task')

    out, ok = release('prepare', '2026.10.0')

    expect(ok).to be(true), out
    expect(File.read(compose_file)).to eq(compose_with('2026.10.0'))
  end

  it 'refuses to prepare without the release image in compose.yml, and changes nothing' do
    pull_request_writing(5, 'feat: build here', 'compose.yml' => "services:\n  web:\n    build: .\n")

    out, ok = release('prepare', '2026.10.0')

    expect(ok).to be(false)
    expect(out).to include('names ghcr.io/lalabase/lalabase 0 times', 'nothing was changed')
    expect(File.read(File.join(work, 'CHANGELOG.md'))).not_to include('2026.10.0')
  end

  it 'tells to compare compose.yml only for a change beyond the image version' do
    pull_request_writing(5, 'chore: next image', 'compose.yml' => compose_with('2026.9.1'))
    expect(release('draft').first).not_to include('compose.yml changed')

    pull_request_writing(6, 'fix: restart', 'compose.yml' => compose_with('2026.9.1', restart: 'always'))
    expect(release('draft').first).to include('compose.yml changed: compare it with your copy')
  end

  context 'when the notes are on main' do
    before do
      merge_pull_request(5, 'feat: one task')
      git('switch', '-q', '-c', 'release-notes')
      release('prepare', '2026.10.0')
      git('commit', '-q', '-am', 'release notes 2026.10.0')
      git('switch', '-q', 'main')
      git('merge', '-q', '--no-ff', 'release-notes', '-m', 'Merge pull request #7 from someone/release-notes')
      git('push', '-q', 'origin', 'main')
    end

    it 'refuses to publish while compose.yml pulls another release, before tagging anything' do
      pull_request_writing(9, 'chore: back to the old image', 'compose.yml' => compose_with('2026.9.0'))

      out, ok = release('publish', '2026.10.0', '--anyway')

      expect(ok).to be(false)
      expect(out).to include('compose.yml on main pulls the image of 2026.9.0, not 2026.10.0')
      expect(git('tag', '--list', '2026.10.0').strip).to eq('')
    end

    # The notes pull request (#7) changed the image version too and needs no
    # line. One that changes compose.yml beyond it is code and needs one.
    it 'wants a line for a notes pull request that also changed compose.yml beyond the version' do
      notes = File.read(File.join(work, 'CHANGELOG.md'))
      pull_request_writing(9, 'docs: notes and a restart',
                           'CHANGELOG.md' => notes.sub('- one task (#5)', "- one task (#5)\n- more"),
                           'compose.yml' => compose_with('2026.10.0', restart: 'always'))

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('not in the release notes: #9')
    end

    # A pull request merged between prepare and publish would be in no release (finding 2).
    it 'stops when a pull request was merged after the notes, unless told --anyway' do
      merge_pull_request(8, 'fix: late one')

      out, ok = release('publish', '2026.10.0')
      expect(ok).to be(false)
      expect(out).to include('not in the release notes: #8')
      expect(git('tag', '--list', '2026.10.0').strip).to eq('')

      expect(release('publish', '2026.10.0', '--anyway').last).to be(true)
    end

    it 'refuses to publish notes that still have unsorted entries' do
      git('switch', '-q', '-c', 'more-notes')
      notes = File.read(File.join(work, 'CHANGELOG.md'))
      File.write(File.join(work, 'CHANGELOG.md'),
                 notes.sub('### Upgrade notes', "### Unsorted (move or delete before publishing)\n\n- x (#9)\n\n### Upgrade notes"))
      git('commit', '-q', '-am', 'notes with unsorted')
      git('switch', '-q', 'main')
      git('merge', '-q', '--no-ff', 'more-notes', '-m', 'Merge pull request #10 from someone/more-notes')
      git('push', '-q', 'origin', 'main')

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('unsorted entries left: 2026.10.0')
      expect(git('tag', '--list', '2026.10.0').strip).to eq('')
    end

    # Review 2, point 2a: a later pull request touching CHANGELOG.md must not hide an earlier one.
    it 'stops when a pull request came after the notes, also when a later one changed CHANGELOG.md' do
      merge_pull_request(8, 'fix: late one')
      changelog_pull_request(9) { |path| File.write(path, File.read(path).sub("## [Unreleased]\n", "## [Unreleased]\n\n- by hand\n")) }

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('not in the release notes: #8', 'Unreleased is not empty')
    end

    # Only a pull request that changed nothing BUT CHANGELOG.md is the notes themselves.
    it 'stops for a pull request that changed CHANGELOG.md and code' do
      git('switch', '-q', '-c', 'pr-16')
      File.write(File.join(work, 'code16.rb'), 'x')
      File.write(File.join(work, 'CHANGELOG.md'), File.read(File.join(work, 'CHANGELOG.md')).sub('- one task (#5)', "- one task (#5)\n- also"))
      git('add', '-A')
      git('commit', '-q', '-m', 'code and notes')
      git('switch', '-q', 'main')
      git('merge', '-q', '--no-ff', 'pr-16', '-m', 'Merge pull request #16 from someone/pr-16')
      git('push', '-q', 'origin', 'main')

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('not in the release notes: #16')
    end

    it 'refuses while Unreleased has lines: they would wait for the next release unseen' do
      changelog_pull_request(9) { |path| File.write(path, File.read(path).sub("## [Unreleased]\n", "## [Unreleased]\n\n- by hand\n")) }

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('Unreleased is not empty')
    end

    # Review 2, point 3: publish reads the notes, so it asks the rules itself.
    it 'checks the shape of CHANGELOG.md itself' do
      changelog_pull_request(9) { |path| File.write(path, File.read(path).sub('## [2026.10.0]', "## Notes\n\n## [2026.10.0]")) }

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('not a release heading: ## Notes')
    end

    # Review 2, point 7: main moved on after the tag was pushed.
    it 'finishes a half-done publish after main moved on, with the notes of the tag' do
      File.write(File.join(state, 'fail_create'), '')
      expect(release('publish', '2026.10.0').last).to be(false)
      merge_pull_request(14, 'feat: after the tag')
      changelog_pull_request(15) { |path| File.write(path, File.read(path).sub('- one task (#5)', "- one task (#5)\n- edited after the tag")) }

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(true), out
      expect(File.read(File.join(state, 'release-2026.10.0'))).to include('- one task (#5)')
      expect(File.read(File.join(state, 'release-2026.10.0'))).not_to include('edited after the tag')
      expect(File.read(File.join(state, 'release-2026.10.0'))).not_to include('drafted from')
    end

    it 'refuses to start when gh is not logged in, before tagging anything' do
      File.write(File.join(state, 'logged_out'), '')

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('gh is not logged in')
      expect(git('tag', '--list', '2026.10.0').strip).to eq('')
    end

    # Finding 4: tagged and pushed, then gh failed; the next run finishes the job.
    it 'finishes a publish that failed after the tag was pushed' do
      File.write(File.join(state, 'fail_create'), '')
      expect(release('publish', '2026.10.0').last).to be(false)
      expect(git('ls-remote', '--tags', 'origin', '2026.10.0')).to include('refs/tags/2026.10.0')

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(true), out
      expect(File.read(File.join(state, 'release-2026.10.0'))).to include('- one task (#5)')
    end

    # Review 3, finding C: the advice of the refusal has to work.
    it 'publishes once the late pull request is written into the section by hand' do
      merge_pull_request(8, 'fix: late one')
      changelog_pull_request(9) { |path| File.write(path, File.read(path).sub('- one task (#5)', "- one task (#5)\n- late one (#8)")) }

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(true), out
      expect(File.read(File.join(state, 'release-2026.10.0'))).to include('- late one (#8)')
    end

    # Review 3, finding D: only the pull request merged into main is the notes, not a commit inside it.
    it 'does not let a commit inside a notes pull request excuse a real one with its number' do
      merge_pull_request(8, 'fix: late one')
      git('switch', '-q', '-c', 'typo')
      path = File.join(work, 'CHANGELOG.md')
      File.write(path, File.read(path).sub('- one task (#5)', '- one task (#5).'))
      git('commit', '-q', '-am', 'typo in the notes (#8)')
      git('switch', '-q', 'main')
      git('merge', '-q', '--no-ff', 'typo', '-m', 'Merge pull request #9 from someone/typo')
      git('push', '-q', 'origin', 'main')

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('not in the release notes: #8')
    end

    # Review 3, finding A: a rebase merge or a direct push carries no pull request number.
    it 'refuses a commit on main that came without a pull request' do
      File.write(File.join(work, 'rebased.txt'), 'x')
      git('add', '-A')
      git('commit', '-q', '-m', 'fix: the rebased one')
      git('push', '-q', 'origin', 'main')

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('On main without a pull request', 'fix: the rebased one')
    end

    # Review 3, finding K: a tag on origin is not trusted just for being there.
    it 'refuses to release a tag on origin that is not on main or whose notes are not in shape' do
      git('switch', '-q', '-c', 'unmerged')
      path = File.join(work, 'CHANGELOG.md')
      File.write(path, File.read(path).sub('### Upgrade notes', "### Unsorted (move or delete before publishing)\n\n- unreviewed (#99)\n\n### Upgrade notes"))
      git('commit', '-q', '-am', 'unreviewed')
      git('tag', '-a', '2026.10.0', '-m', 'by hand')
      git('push', '-q', 'origin', '2026.10.0')
      git('switch', '-q', 'main')

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('is not on origin/main')
      expect(File.exist?(File.join(state, 'release-2026.10.0'))).to be(false)
    end

    it 'refuses to release a tag on main whose notes are not in shape' do
      changelog_pull_request(9) do |path|
        File.write(path, File.read(path).sub('### Upgrade notes', "### Unsorted (move or delete before publishing)\n\n- x (#99)\n\n### Upgrade notes"))
      end
      git('tag', '-a', '2026.10.0', '-m', 'by hand')
      git('push', '-q', 'origin', '2026.10.0')

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('CHANGELOG.md of the tag 2026.10.0 is not in shape', 'unsorted entries left')
      expect(File.exist?(File.join(state, 'release-2026.10.0'))).to be(false)
    end

    # Review 3, finding J: a tag that was never pushed, and main moved on.
    it 'says how to get past a local tag that was never pushed' do
      git('tag', '-a', '2026.10.0', '-m', 'local only')
      changelog_pull_request(9) { |path| File.write(path, File.read(path).sub('- one task (#5)', '- one task (#5).')) }

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(false)
      expect(out).to include('git tag -d 2026.10.0')
    end

    it 'leaves a finished release alone when run again' do
      expect(release('publish', '2026.10.0').last).to be(true)
      File.write(File.join(state, 'fail_create'), '') # a second create would fail

      out, ok = release('publish', '2026.10.0')

      expect(ok).to be(true), out
      expect(out).to include('The GitHub release 2026.10.0 exists already.')
    end
  end
end
