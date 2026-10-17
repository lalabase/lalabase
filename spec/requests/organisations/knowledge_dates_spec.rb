# frozen_string_literal: true

require 'rails_helper'

# The knowledge list writes its dates in the reader's language. Until 17.10.2026 the
# row formatted them with strftime, which knows only English month names: the German
# page said "14 Oct 2026", and the compact column wrote the German "14.10.26" on the
# English page.
RSpec.describe 'Knowledge list dates', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:created_at) { Time.zone.local(2026, 10, 14, 10, 30) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:note, project: project, organisation: organisation, creator: user, created_at: created_at)
    create(:membership, user: user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation), active: true)
    sign_in user
  end

  def row_dates
    page = Nokogiri::HTML(response.body)
    [page.at_css('.date-full')&.text&.strip, page.at_css('.date-compact')&.text&.strip]
  end

  context 'with a German reader' do
    let(:user) { create(:user, language_preference: 'de') }

    it 'names the month in German' do
      get organisation_project_knowledge_index_path(organisation, project)

      expect(response).to have_http_status(:ok)
      expect(row_dates).to eq(['14. Oktober 2026, 10:30', '14.10.2026'])
    end
  end

  context 'with an English reader' do
    let(:user) { create(:user, language_preference: 'en') }

    it 'names the month in English' do
      get organisation_project_knowledge_index_path(organisation, project)

      expect(response).to have_http_status(:ok)
      expect(row_dates).to eq(['October 14, 2026 10:30', '2026-10-14'])
    end
  end
end
