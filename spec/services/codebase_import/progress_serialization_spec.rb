# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Import progress JSON serialization', type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:import_file) do
    create(:codebase_import_file, organisation: organisation, user: user, project: project,
                                  file_type: file_type, metadata: { 'source' => 'legacy', 'progress' => { 'current' => 0 } })
  end

  before { ActsAsTenant.current_tenant = organisation }

  shared_examples 'a progress writer' do
    it 'replaces persisted progress without duplicate JSON keys or losing other metadata' do
      expect do
        write_progress(1)
        write_progress(2)
      end.not_to output(/duplicate key/).to_stderr

      metadata = import_file.reload.metadata
      expect(metadata['source']).to eq('legacy')
      expect(metadata['progress']).to include('current' => 2, 'total' => 3, 'percentage' => 66.7)
    end
  end

  context 'when importing tickets' do
    let(:file_type) { 'tickets' }
    let(:importer) { CodebaseImport::TicketImporter.new(import_file, project, {}, {}, user) }

    def write_progress(current)
      importer.send(:update_progress_with_tags, current, 3, nil)
    end

    include_examples 'a progress writer'
  end

  context 'when importing time sessions' do
    let(:file_type) { 'time_tracking' }
    let(:importer) { CodebaseImport::TimeSessionImporter.new(import_file, project, user) }

    def write_progress(current)
      importer.send(:update_progress, current, 3)
    end

    include_examples 'a progress writer'
  end
end
