# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DocumentsHelper, type: :helper do
  describe '#document_version_download_path' do
    let(:organisation) { create(:organisation) }
    let(:project) { create(:project, organisation: organisation) }
    let(:document) { create(:document, project: project, organisation: organisation) }
    let(:version) { create(:document_version, document: document, organisation: organisation) }

    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    it 'builds the authorized proxy path for the version (org from the version, not ambient)' do
      path = helper.document_version_download_path(version)

      expect(path).to eq(
        "/org/#{organisation.id}/files/document_version/#{version.id}"
      )
    end

    it 'uses a kind that is actually registered in the proxy (helper <-> registry contract)' do
      # Catches a mutation that turns the kind in the helper into something the proxy
      # doesn't know — otherwise all download links would lead nowhere (404), without any test breaking.
      expect(Organisations::FileDownloadsController::DOWNLOADABLES).to have_key('document_version')
    end
  end
end
