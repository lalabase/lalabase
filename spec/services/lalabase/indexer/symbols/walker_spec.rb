# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Indexer::Symbols::Walker do
  # The walker now routes .ts/.tsx/.js/... through the tree-sitter extractor, so
  # the compiled grammars must exist (shared helper builds them on demand).
  before(:all) { TreeSitterGrammarsHelper.ensure_built! }

  around do |example|
    Dir.mktmpdir('walker-test-') do |dir|
      @dir = dir
      example.run
    end
  end

  def write(rel_path, content)
    full = File.join(@dir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def walker
    described_class.new(@dir)
  end

  describe '#each_file_symbols' do
    it 'yields symbols per Ruby file' do
      write('app/services/foo.rb', 'class Foo; def bar; end; end')
      write('lib/baz.rb',          'module Baz; end')
      results = walker.each_file_symbols.to_a
      qns = results.flat_map { |syms, _| syms.map { |s| s[:qualified_name] } }
      expect(qns).to contain_exactly('Foo', 'Foo#bar', 'Baz')
    end

    it 'yields the relative file_path with each batch' do
      write('app/models/x.rb', 'class X; end')
      results = walker.each_file_symbols.to_a
      _, rel_path = results.first
      expect(rel_path).to eq('app/models/x.rb')
    end

    it 'sets file_path on the symbol relative to repo root (not absolute)' do
      write('app/foo.rb', 'class Foo; end')
      sym = walker.each_file_symbols.to_a.first.first.first
      expect(sym[:file_path]).to eq('app/foo.rb')
    end

    it 'returns an Enumerator when called without a block' do
      write('a.rb', 'class A; end')
      expect(walker.each_file_symbols).to be_a(Enumerator)
    end
  end

  describe '#symbols_for (single-file extraction for incremental re-index)' do
    it 'returns symbols for one Ruby file' do
      write('app/services/foo.rb', 'class Foo; def bar; end; end')
      qns = walker.symbols_for('app/services/foo.rb').map { |s| s[:qualified_name] }
      expect(qns).to contain_exactly('Foo', 'Foo#bar')
    end

    it 'returns [] for a path inside a skipped directory' do
      write('node_modules/x.rb', 'class X; end')
      expect(walker.symbols_for('node_modules/x.rb')).to eq([])
    end

    it 'returns [] for an unsupported extension (e.g. .py)' do
      write('a.py', 'def f(): pass')
      expect(walker.symbols_for('a.py')).to eq([])
    end

    it 'returns [] for a non-existent path' do
      expect(walker.symbols_for('does/not/exist.rb')).to eq([])
    end

    it 'returns [] for a file larger than the size cap' do
      write('big.rb', 'x' * (described_class::MAX_FILE_BYTES + 100))
      expect(walker.symbols_for('big.rb')).to eq([])
    end

    it 'returns [] (no crash) for a syntactically broken file' do
      write('broken.rb', 'def foo((((')
      expect(walker.symbols_for('broken.rb')).to eq([])
    end

    it 'returns [] (no crash) for a broken TS file — dispatch + the extractor rescue' do
      write('src/broken.ts', 'function f( {')
      expect(walker.symbols_for('src/broken.ts')).to eq([])
    end

    # Path-traversal guard: an absolute path (or ../) pointing at a real Ruby
    # file OUTSIDE the repo root must not be read. Without the start_with? guard
    # this would happily parse arbitrary on-disk files.
    it 'refuses an absolute path outside the repo root' do
      outside = File.join(Dir.tmpdir, "walker-outside-#{SecureRandom.hex(4)}.rb")
      File.write(outside, 'class Outside; end')
      expect(walker.symbols_for(outside)).to eq([])
    ensure
      File.delete(outside) if outside && File.exist?(outside)
    end

    # ../-relative escape: resolves (cleanpath) to a real Ruby file OUTSIDE the
    # root. Without the start_with? guard the extractor would happily parse it.
    it 'refuses a ../-relative path that escapes the repo root' do
      outside = File.join(Dir.tmpdir, "walker-outside-#{SecureRandom.hex(4)}.rb")
      File.write(outside, 'class OutsideRel; end')
      rel = Pathname.new(outside).relative_path_from(Pathname.new(@dir)).to_s
      expect(rel).to start_with('..') # sanity: we really are climbing out
      expect(walker.symbols_for(rel)).to eq([])
    ensure
      File.delete(outside) if outside && File.exist?(outside)
    end

    # Language dispatch via EXTENSION_REGISTRY — each extension routed to the right
    # extractor with the right language tag. Dropping or mis-tagging an extension
    # must break a test, not pass silently.
    %w[.rb .rake].each do |ext|
      it "routes #{ext} to the Ruby extractor (language: ruby)" do
        write("lib/thing#{ext}", 'class Thing; end')
        symbols = walker.symbols_for("lib/thing#{ext}")
        expect(symbols.map { |s| s[:qualified_name] }).to include('Thing')
        expect(symbols.first[:language]).to eq('ruby')
      end
    end

    { '.ts' => 'typescript', '.js' => 'javascript', '.mjs' => 'javascript', '.cjs' => 'javascript' }.each do |ext, lang|
      it "routes #{ext} to the TS extractor via the typescript grammar (language: #{lang})" do
        write("src/thing#{ext}", 'export class Thing {}')
        symbols = walker.symbols_for("src/thing#{ext}")
        expect(symbols.map { |s| s[:qualified_name] }).to contain_exactly('Thing')
        expect(symbols.first[:language]).to eq(lang)
      end
    end

    # .tsx/.jsx must use the tsx grammar: this JSX snippet errors (→ []) under the
    # plain typescript grammar, so a wrong-grammar routing fails the test.
    { '.tsx' => 'typescript', '.jsx' => 'javascript' }.each do |ext, lang|
      it "routes #{ext} through the tsx grammar so JSX parses (language: #{lang})" do
        write("src/Comp#{ext}", 'export const Comp = () => <div>hi</div>')
        symbols = walker.symbols_for("src/Comp#{ext}")
        expect(symbols.map { |s| s[:qualified_name] }).to contain_exactly('Comp')
        expect(symbols.first[:language]).to eq(lang)
      end
    end

    it 'tags EVERY symbol (not just the first) for a multi-symbol .js file — kwargs reach nested emits' do
      write('src/m.js', 'namespace N { export class Inner { m() {} } }')
      langs = walker.symbols_for('src/m.js').map { |s| s[:language] }
      expect(langs.size).to be >= 3
      expect(langs).to all(eq('javascript'))
    end

    it 'reads a file exactly at the size cap (boundary n, complements the >n skip test)' do
      content = "class AtCap\nend\n".ljust(described_class::MAX_FILE_BYTES, ' ')[0, described_class::MAX_FILE_BYTES]
      write('atcap.rb', content)
      expect(walker.symbols_for('atcap.rb').map { |s| s[:name] }).to include('AtCap')
    end
  end

  describe 'extension filtering' do
    described_class::EXTENSION_REGISTRY.each_key do |ext|
      it "counts #{ext} as an indexable extension" do
        write("x#{ext}", 'code') # file_count filters by extension only, never parses
        expect(walker.file_count).to eq(1)
      end
    end

    it 'skips unsupported files (.py / .md / no-extension)' do
      %w[a.py c.md README Makefile].each { |n| write(n, 'irrelevant') }
      expect(walker.file_count).to eq(0)
    end
  end

  describe 'directory exclusion' do
    described_class::SKIP_DIRS.each do |skip_dir|
      it "skips files under #{skip_dir}/ (single-segment directory name)" do
        write("#{skip_dir}/code.rb", 'class X; end')
        expect(walker.file_count).to eq(0)
      end
    end

    it 'skips hidden directories (starting with .)' do
      write('.hidden/x.rb', 'class X; end')
      expect(walker.file_count).to eq(0)
    end

    it 'does not skip the same name appearing as a SUFFIX of another dir' do
      # "vendor_legacy/" should NOT be skipped just because "vendor" is in SKIP_DIRS
      write('vendor_legacy/x.rb', 'class X; end')
      expect(walker.file_count).to eq(1)
    end

    it 'does NOT skip a top-level file literally named after a skip-dir (e.g. vendor.rb)' do
      # Bug class: if skipped? matches on filename instead of dirname, a file
      # called `vendor.rb` would be skipped despite being legitimate code.
      write('vendor.rb', 'class V; end')
      expect(walker.file_count).to eq(1)
    end
  end

  describe 'file-size cap' do
    it 'skips files larger than MAX_FILE_BYTES' do
      huge = 'x' * (described_class::MAX_FILE_BYTES + 100)
      write('big.rb', huge)
      expect(walker.file_count).to eq(1) # still counted in file_count
      expect(walker.each_file_symbols.to_a).to be_empty # but read_safely returns nil → no yield
    end

    it 'reads files exactly at the cap boundary (n)' do
      content = "class A\nend\n" + ('# pad ' * 100)
      content = content[0, described_class::MAX_FILE_BYTES]
      write('atcap.rb', content)
      symbols = walker.each_file_symbols.to_a.first&.first
      expect(symbols).to include(an_object_satisfying { |s| s[:name] == 'A' })
    end
  end

  describe 'tolerance of pathological files' do
    it 'does not crash on a syntactically broken Ruby file' do
      write('broken.rb', 'def foo((((')
      expect { walker.each_file_symbols.to_a }.not_to raise_error
    end

    it 'does not crash when a file is deleted between glob and read (ENOENT race)' do
      # Walker.file_count materialises the list at construction time. If a file
      # disappears between that snapshot and the per-file `path.size`/`path.read`,
      # we must rescue Errno::ENOENT. Defense against fast-moving filesystems
      # (CI containers, watched dirs). The rescue MUST cover both path.size AND
      # path.read — if someone narrows it to a begin/end block around just
      # path.read, the size check still raises and breaks indexing.
      write('vanishing.rb', 'class V; end')
      w = walker
      File.delete(File.join(@dir, 'vanishing.rb'))
      expect { w.each_file_symbols.to_a }.not_to raise_error
    end

    it 'does not crash on EACCES (unreadable file)' do
      write('secret.rb', 'class S; end')
      File.chmod(0o000, File.join(@dir, 'secret.rb'))
      expect { walker.each_file_symbols.to_a }.not_to raise_error
    ensure
      File.chmod(0o644, File.join(@dir, 'secret.rb')) if File.exist?(File.join(@dir, 'secret.rb'))
    end
  end

  describe 'constants locked as contract' do
    it { expect(described_class::MAX_FILE_BYTES).to eq(500_000) }
    it { expect(described_class::SKIP_DIRS).to include('node_modules', 'vendor', 'tmp') }

    it 'maps exactly the supported extensions in EXTENSION_REGISTRY' do
      registry = described_class::EXTENSION_REGISTRY
      expect(registry.keys).to contain_exactly('.rb', '.rake', '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs')
    end

    it 'only assigns languages CodeSymbol accepts (defense-in-depth vs a registry typo)' do
      languages = described_class::EXTENSION_REGISTRY.values.filter_map { |_klass, kwargs| kwargs[:language] }
      expect(languages.uniq).to all(be_in(CodeSymbol::LANGUAGES))
    end

    it 'routes Ruby with no extra kwargs and TS/JS with language + grammar' do
      registry = described_class::EXTENSION_REGISTRY
      expect(registry.fetch('.rb')).to eq([Lalabase::Indexer::Symbols::RubyExtractor, {}])
      expect(registry.fetch('.tsx')).to eq([Lalabase::Indexer::Symbols::TypescriptExtractor,
                                            { language: 'typescript', grammar: 'tsx' }])
      expect(registry.fetch('.js')).to eq([Lalabase::Indexer::Symbols::TypescriptExtractor,
                                           { language: 'javascript', grammar: 'typescript' }])
    end
  end

  describe '#file_count' do
    it 'returns the number of Ruby files (after filtering)' do
      write('a.rb', 'class A; end')
      write('b.rb', 'class B; end')
      write('node_modules/c.rb', 'class C; end') # skipped
      expect(walker.file_count).to eq(2)
    end

    it 'caches the result so iteration uses the same list' do
      write('a.rb', 'class A; end')
      count_before = walker.file_count
      walker.each_file_symbols.to_a # would invalidate if not cached
      expect(walker.file_count).to eq(count_before)
    end
  end
end
