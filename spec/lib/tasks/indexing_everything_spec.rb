# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake indexing:everything[ORG_ID]`, the one-off for the stock after
#   doc/notizen_immer_indexiert_plan.md.
# Type: Rake task spec.
# Why: the service spec beside it proves WHAT a run does; this holds what only the
#   task decides: WHICH organisations a run is aimed at. One id means that one, no
#   id means all, and a mistyped id must abort instead of silently turning into
#   "everyone" (the costliest mistake of a metered run). Plus the output, the only
#   preview an operator gets.
RSpec.describe 'indexing:everything' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('indexing:everything')
  end

  before { Rake::Task['indexing:everything'].reenable }

  let!(:organisation) { create(:organisation, name: 'Eine') }
  let!(:other_organisation) { create(:organisation, name: 'Andere') }
  let(:result) { Indexing::IndexEverything::Result.new(flipped: 2, enqueued: 3, reason: nil) }

  it 'runs the service for the one organisation named' do
    allow(Indexing::IndexEverything).to receive(:call).and_return(result)

    output = capture_output { Rake::Task['indexing:everything'].invoke(organisation.id) }

    expect(Indexing::IndexEverything).to have_received(:call).with(organisation: organisation).once
    expect(Indexing::IndexEverything).not_to have_received(:call).with(organisation: other_organisation)
    expect(output).to include('Eine').and include('flipped 2, enqueued 3')
  end

  it 'runs it for every organisation without an id, and names the reason where nothing was enqueued' do
    refused = Indexing::IndexEverything::Result.new(flipped: 1, enqueued: 0, reason: :no_credential)
    allow(Indexing::IndexEverything).to receive(:call).and_return(result, refused)

    output = capture_output { Rake::Task['indexing:everything'].invoke }

    expect(Indexing::IndexEverything).to have_received(:call).twice
    expect(output).to include('nothing enqueued (no_credential)')
  end

  it 'aborts on an id that names no organisation instead of running for everyone' do
    allow(Indexing::IndexEverything).to receive(:call)

    expect { Rake::Task['indexing:everything'].invoke(SecureRandom.uuid) }.to raise_error(SystemExit)
    expect(Indexing::IndexEverything).not_to have_received(:call)
  end

  def capture_output
    output = StringIO.new
    original = $stdout
    $stdout = output
    yield
    output.string
  ensure
    $stdout = original
  end
end
