# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake documents:number_versions[ORG_ID]`, the stock's version numbers.
# Type: Rake task spec; the service spec beside it proves what a run does, this
#   holds which organisations a run is aimed at: one id, all, and a mistyped id
#   aborts instead of silently meaning everyone.
RSpec.describe 'documents:number_versions' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('documents:number_versions')
  end

  before { Rake::Task['documents:number_versions'].reenable }

  let!(:organisation) { create(:organisation, name: 'Eine') }
  let!(:other_organisation) { create(:organisation, name: 'Andere') }
  let(:result) { Documents::NumberVersions::Result.new(documents: 2, versions: 5) }

  it 'runs the service for the one organisation named' do
    allow(Documents::NumberVersions).to receive(:call).and_return(result)

    output = capture_output { Rake::Task['documents:number_versions'].invoke(organisation.id) }

    expect(Documents::NumberVersions).to have_received(:call).with(organisation: organisation).once
    expect(Documents::NumberVersions).not_to have_received(:call).with(organisation: other_organisation)
    expect(output).to include('Eine').and include('2 documents, 5 versions numbered')
  end

  it 'runs it for every organisation without an id' do
    allow(Documents::NumberVersions).to receive(:call).and_return(result)

    capture_output { Rake::Task['documents:number_versions'].invoke }

    expect(Documents::NumberVersions).to have_received(:call).twice
  end

  it 'aborts on an id that names no organisation' do
    allow(Documents::NumberVersions).to receive(:call)

    expect { Rake::Task['documents:number_versions'].invoke(SecureRandom.uuid) }.to raise_error(SystemExit)
    expect(Documents::NumberVersions).not_to have_received(:call)
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
