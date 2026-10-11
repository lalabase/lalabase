# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../../lib/lalabase/leak_guard'

# What: script/leak_guard end to end, in a throwaway repository with a key and
#       words of its own.
# Why:  The review of #969 found the workflow green while it checked nothing:
#       a wrong key found nothing, a range gitleaks could not resolve scanned
#       nothing, and what a commit added and removed again, or said in its
#       message, was never read. None of that shows in Lalabase::LeakGuard alone.
RSpec.describe 'script/leak_guard', :ci_guard do
  let(:root) { File.expand_path('../../..', __dir__) }
  let(:key) { 'test-key-not-the-real-one' }
  let(:word) { 'prod.secret.example' }

  around do |example|
    Dir.mktmpdir('leak-guard-script-') do |tmp|
      @work = File.join(tmp, 'work')
      FileUtils.mkdir_p(@work)
      example.run
    end
  end

  def git(*args)
    out, status = Open3.capture2e('git', '-C', @work, '-c', 'user.email=t@example.com', '-c', 'user.name=t', *args)
    raise "git #{args.join(' ')}: #{out}" unless status.success?

    out.strip
  end

  def commit(message, files = {})
    files.each do |path, text|
      FileUtils.mkdir_p(File.dirname(File.join(@work, path)))
      text.nil? ? File.delete(File.join(@work, path)) : File.binwrite(File.join(@work, path), text)
    end
    git('add', '-A')
    git('commit', '-q', '--allow-empty', '-m', message)
    git('rev-parse', 'HEAD')
  end

  def guard(*args, env: { 'LEAK_GUARD_KEY' => key }, script: File.join(@work, 'script/leak_guard'))
    out, status = Open3.capture2e(env, 'ruby', script, *args, chdir: @work)
    [out, status.success?]
  end

  before do
    git('init', '-q', '-b', 'main')
    FileUtils.mkdir_p([File.join(@work, 'script'), File.join(@work, 'lib/lalabase'), File.join(@work, 'config')])
    FileUtils.cp(File.join(root, 'script/leak_guard'), File.join(@work, 'script/leak_guard'))
    FileUtils.cp(File.join(root, 'lib/lalabase/leak_guard.rb'), File.join(@work, 'lib/lalabase/leak_guard.rb'))
    File.write(File.join(@work, '.gitleaks.toml'), "title = \"x\"\n")
    File.write(File.join(@work, Lalabase::LeakGuard::DIGESTS_FILE),
               "key-check #{Lalabase::LeakGuard.key_check(key)}\n#{Lalabase::LeakGuard.digest(key, word)}\n")
    @base = commit('init')
  end

  it 'passes a clean checkout' do
    out, ok = guard

    expect(ok).to be(true), out
    expect(out).to include('nothing found')
  end

  # Review of #969, point 1.
  it 'stops with a key the digests were not made with, instead of finding nothing' do
    out, ok = guard(env: { 'LEAK_GUARD_KEY' => 'wrong-key' })

    expect(ok).to be(false)
    expect(out).to include('LEAK_GUARD_KEY is not the key')
  end

  it 'reads a quoted key from .env' do
    File.write(File.join(@work, '.env'), %(OTHER=1\nLEAK_GUARD_KEY="#{key}"\n))

    out, ok = guard(env: { 'LEAK_GUARD_KEY' => nil })

    expect(ok).to be(true), out
  end

  # Review 2 of #969, finding 6.
  it 'reads a file behind a NUL byte and a UTF-16 file' do
    commit('odd texts', 'notes.txt' => "\x00host #{word}\n", 'export.csv' => "\xFF\xFE".b + "host,#{word}\n".encode('UTF-16LE').b)

    out, ok = guard

    expect(ok).to be(false)
    expect(out).to include('notes.txt:1', 'export.csv:1')
  end

  # Final review of #969, finding 2: the branch name and the title become the merge commit on main.
  describe 'pull-request' do
    it 'finds a listed word in the branch name, the title or the body of the pull request' do
      out, ok = guard('pull-request', env: { 'LEAK_GUARD_KEY' => key, 'LEAK_GUARD_PR_BRANCH' => "fix/#{word}-backup",
                                             'LEAK_GUARD_PR_TITLE' => 'fix(backup): retry', 'LEAK_GUARD_PR_BODY' => '' })

      expect(ok).to be(false)
      expect(out).to include('pull request branch:1: a word only')
      expect(guard('pull-request', env: { 'LEAK_GUARD_KEY' => key, 'LEAK_GUARD_PR_TITLE' => "retry on #{word}" }))
        .to match([a_string_including('pull request title:1'), false])
      expect(guard('pull-request', env: { 'LEAK_GUARD_KEY' => key, 'LEAK_GUARD_PR_TITLE' => 'fix: retry',
                                          'LEAK_GUARD_PR_BODY' => "Steps\nssh deploy@#{word}" }))
        .to match([a_string_including('pull request body:2'), false])
    end

    it 'passes a clean pull request, and stops when it is given nothing to check' do
      expect(guard('pull-request', env: { 'LEAK_GUARD_KEY' => key, 'LEAK_GUARD_PR_BRANCH' => 'fix/retry',
                                          'LEAK_GUARD_PR_TITLE' => 'fix: retry' }).last).to be(true)
      expect(guard('pull-request', env: { 'LEAK_GUARD_KEY' => key })).to match([a_string_including('nothing was checked'), false])
    end
  end

  # Review 2 of #969, finding 3: a pull request does not judge itself.
  describe 'net BASE DIR' do
    it 'takes the leak net from the base, and says which files the checkout changes' do
      commit('weaken', Lalabase::LeakGuard::DIGESTS_FILE => "key-check #{Lalabase::LeakGuard.key_check(key)}\n#{'0' * 64}\n",
                       'notes.txt' => "host #{word}\n")
      net = File.join(@work, '..', 'net')

      out, ok = guard('net', @base, net)

      expect(ok).to be(true), out
      expect(out).to include('changes the leak net: config/leak_guard.digests')
      expect(guard(env: { 'LEAK_GUARD_KEY' => key, 'LEAK_GUARD_ROOT' => @work }, script: File.join(net, 'script/leak_guard')))
        .to match([a_string_including('notes.txt:1'), false])
      expect(guard.last).to be(true)
    end

    # Final review of #969, finding 3: the label must not hide what changed.
    it 'names the changed net files also when told to use the checkout\'s own net' do
      commit('weaken', Lalabase::LeakGuard::DIGESTS_FILE => "key-check #{Lalabase::LeakGuard.key_check(key)}\n#{'0' * 64}\n")

      out, ok = guard('net', @base, File.join(@work, '..', 'net-label'), '--own')

      expect(ok).to be(true), out
      expect(out).to include('Leak net from this checkout: config/leak_guard.digests',
                             'changes the leak net: config/leak_guard.digests')
    end

    it 'takes a file the base does not have from the checkout' do
      out, ok = guard('net', '', File.join(@work, '..', 'net-own'))

      expect(ok).to be(true), out
      expect(out).to include('from this checkout: script/leak_guard')
    end
  end

  # Review of #969, point 13: a link points at a path on someone's machine.
  it 'refuses a tracked symbolic link' do
    File.symlink('/somewhere/else', File.join(@work, 'storage'))
    commit('link')

    out, ok = guard

    expect(ok).to be(false)
    expect(out).to include('storage: a symbolic link')
  end

  # Review of #969, point 12.
  it 'refuses a gitleaks config with exceptions by path' do
    commit('config', '.gitleaks.toml' => "[[rules.allowlists]]\npaths = ['''x''']\n")

    out, ok = guard

    expect(ok).to be(false)
    expect(out).to include('.gitleaks.toml: paths =')
  end

  # Review of #969, point 3.
  describe 'history RANGE' do
    it 'finds a word that a commit added and a later one removed, and a word in a message' do
      commit('add', 'notes.txt' => "host #{word}\n")
      commit('remove', 'notes.txt' => nil)
      commit("talk about #{word}")

      expect(guard.last).to be(true)
      out, ok = guard('history', "#{@base}..HEAD")

      expect(ok).to be(false)
      expect(out).to match(/\h{10} notes\.txt \(added\):1/).and match(/\h{10} \(message\):1/)
      expect(out).not_to include(word)
    end

    it 'finds what a merge added while resolving a conflict' do
      commit('one', 'f.txt' => "one\n")
      git('switch', '-q', '-c', 'side', 'HEAD~1')
      commit('two', 'f.txt' => "two\n")
      git('switch', '-q', 'main')
      Open3.capture2e('git', '-C', @work, 'merge', '-q', 'side')
      File.write(File.join(@work, 'f.txt'), "both #{word}\n")
      git('add', '-A')
      git('commit', '-q', '-m', 'merge side')

      out, ok = guard('history', "#{@base}..HEAD")

      expect(ok).to be(false)
      expect(out).to match(/\h{10} f\.txt \(added\):1/)
    end

    # Found while trying it on real history: one NUL byte in a diff blanked all of it.
    # git looks for binary content in the first 8000 bytes only.
    it 'still reads the range when a commit added a text file with a NUL byte far inside' do
      commit('binary-ish', 'odd.txt' => "#{"text\n" * 2000}a\x00b\n")
      commit("talk about #{word}")

      out, ok = guard('history', "#{@base}..HEAD")

      expect(ok).to be(false)
      expect(out).to match(/\h{10} \(message\):1/)
    end

    it 'refuses a file that holds secrets by nature, also when a later commit removed it' do
      commit('oops', '.env' => "X=1\n")
      commit('remove it', '.env' => nil)

      out, ok = guard('history', "#{@base}..HEAD")

      expect(ok).to be(false)
      expect(out).to match(/\h{10} \.env: holds secrets or data by nature/)
    end

    # Review 2 of #969, findings 4 and 5: what comes without an added text line.
    it 'refuses files by their names in every commit: binary, odd paths, renames, links' do
      commit('binary', 'prod.sqlite3' => "SQLite\x00\x01")
      commit('odd paths', 'my dir/.env' => "X=1\n", 'ä/.env' => "X=1\n")
      File.symlink('/Users/someone/x', File.join(@work, 'link'))
      commit('link')
      commit('rename', 'base.txt' => "x\n")
      git('mv', 'base.txt', "#{word}.md")
      commit('renamed')
      commit('clean up', 'prod.sqlite3' => nil, 'my dir/.env' => nil, 'ä/.env' => nil, 'link' => nil, "#{word}.md" => nil)

      expect(guard.last).to be(true)
      out, ok = guard('history', "#{@base}..HEAD")

      expect(ok).to be(false)
      expect(out).to include('prod.sqlite3: holds secrets', 'my dir/.env: holds secrets', 'ä/.env: holds secrets',
                             'link: a symbolic link')
      expect(out).to match(/\h{10} \S+\.md \(name\): a word only/)
      expect(out).to include('New binary files', 'prod.sqlite3')
    end

    # Review 2 of #969, finding 8: no fixed marker line can end a message early.
    it 'reads a whole message, whatever lines it carries' do
      commit("harmless\n\nleak-guard-end-of-message\nssh deploy@#{word}")

      out, ok = guard('history', "#{@base}..HEAD")

      expect(ok).to be(false)
      expect(out).to match(/\(message\):4/)
    end

    # Review 2 of #969, finding 1: an attribute that hides a diff hides nothing here.
    it 'reads a file that .gitattributes keeps out of diffs' do
      commit('attributes', '.gitattributes' => "*.yml -diff\n", 'c.yml' => "host: #{word}\n")

      out, ok = guard('history', "#{@base}..HEAD")

      expect(ok).to be(false)
      expect(out).to match(/c\.yml \(added\):1/)
    end

    it 'stops on a range without commits instead of passing it' do
      out, ok = guard('history', 'HEAD..HEAD')

      expect(ok).to be(false)
      expect(out).to include('no commits')
    end

    # Final review of #969, finding 1: another machine or an agent with another user.email.
    it 'finds a listed word in the author or committer of a commit' do
      File.write(File.join(@work, 'a.txt'), "x\n")
      git('add', '-A')
      env = { 'GIT_AUTHOR_EMAIL' => "ops@#{word}", 'GIT_COMMITTER_EMAIL' => "ops@#{word}" }
      out, status = Open3.capture2e(env, 'git', '-C', @work, '-c', 'user.name=t', 'commit', '-q', '-m', 'feat: a file')
      raise out unless status.success?

      out, ok = guard('history', "#{@base}..HEAD")

      expect(ok).to be(false), out
      expect(out).to match(/\h{10} \(identity\):1: a word only/)
      expect(out).not_to include(word)
    end

    it 'passes a clean range' do
      commit('fine', 'a.txt' => "nothing\n")

      out, ok = guard('history', "#{@base}..HEAD")

      expect(ok).to be(true), out
    end
  end

  # Review of #969, point 2: gitleaks scans 0 commits of a range git cannot resolve, and says so in green.
  describe 'range BASE' do
    # stdout only: the workflow reads it, and a warning on stderr is not part of it.
    def range(base) = Open3.capture3('ruby', File.join(@work, 'script/leak_guard'), 'range', base, chdir: @work).first

    it 'prints the range from a base in the clone, and HEAD without one' do
      expect(range(@base)).to eq("#{@base}..HEAD\n")
      expect(range('')).to eq("HEAD\n")
      expect(range('0' * 40)).to eq("HEAD\n")
    end

    it 'stops on a base that is not in the clone' do
      out, ok = guard('range', 'deadbeef' * 5)

      expect(ok).to be(false)
      expect(out).to include('not a commit in this clone')
    end
  end
end
