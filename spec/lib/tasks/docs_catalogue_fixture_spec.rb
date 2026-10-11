# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake docs:catalogue_fixture`, which refreshes the recorded catalogue the
#   help specs read (spec/fixtures/docs_catalogue).
# Type: Rake task spec.
# Why:  the fixture is CHECKED IN, so what this task copies ends up in the
#   repository. It used to copy the whole handbook, which put the documentation
#   text into a repository that is going open source in JSON form
#   (doc/docs_delivery_plan.md, goal 1). The task's refusal is the one cheap
#   place to stop that happening again, and a refusal without a spec is a
#   comment: it would still abort, but nobody would notice if a later edit
#   dropped it.
RSpec.describe 'docs:catalogue_fixture' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('docs:catalogue_fixture')
  end

  let(:source) { Pathname.new(Dir.mktmpdir) }
  let(:target) { Pathname.new(Dir.mktmpdir) }

  before do
    Rake::Task['docs:catalogue_fixture'].reenable
    # The task writes into the real fixture directory; point it at a temporary
    # one so a run here cannot change what the suite reads.
    allow(Rails).to receive(:root).and_return(Pathname.new(Rails.root.to_s))
    allow(Rails.root).to receive(:join).and_call_original
    allow(Rails.root).to receive(:join).with('spec/fixtures/docs_catalogue').and_return(target)
  end

  after do
    [source, target].each { |dir| FileUtils.remove_entry(dir) if dir.exist? }
  end

  def write_catalogue(locale, pages)
    source.join("docs_catalogue.#{locale}.json").write(
      JSON.generate(format_version: 1, locale: locale, pages: pages)
    )
  end

  def pages(count)
    Array.new(count) { |i| { slug: "guides/basics/page-#{i}", title: "Page #{i}" } }
  end

  def run_task
    output = StringIO.new
    original = $stdout
    $stdout = output
    Rake::Task['docs:catalogue_fixture'].invoke(source.to_s)
    output.string
  ensure
    $stdout = original
    Rake::Task['docs:catalogue_fixture'].reenable
  end

  it 'copies an example catalogue' do
    write_catalogue('de', pages(2))
    write_catalogue('en', pages(2))

    expect { run_task }.not_to raise_error
    expect(target.glob('docs_catalogue.*.json').map { |f| f.basename.to_s })
      .to contain_exactly('docs_catalogue.de.json', 'docs_catalogue.en.json')
  end

  it 'REFUSES the handbook, and says how many pages it saw' do
    write_catalogue('de', pages(42))
    write_catalogue('en', pages(42))

    expect { run_task }.to raise_error(SystemExit)
    # The refusal is the point: nothing may land in the repository.
    expect(target.glob('docs_catalogue.*.json')).to be_empty
  end

  it 'refuses even when only ONE language is the handbook' do
    # A half-copied pair is the worst outcome: the suite would read two pages in
    # one language and the handbook in the other, and look fine.
    write_catalogue('de', pages(42))
    write_catalogue('en', pages(2))

    expect { run_task }.to raise_error(SystemExit)
    expect(target.glob('docs_catalogue.*.json')).to be_empty
  end

  it 'refuses an empty source rather than reporting success' do
    expect { run_task }.to raise_error(SystemExit)
  end
end
