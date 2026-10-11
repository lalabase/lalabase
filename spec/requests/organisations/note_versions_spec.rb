# frozen_string_literal: true

require 'rails_helper'

# What:  Organisations::NoteVersionsController — read-only version history + diff.
# Type:  Request spec.
# Why:   Access mirrors the note itself (policy_scope(Note)); a user who cannot read the
#        note must not reach its history or diff. Plus a smoke test that history + diff
#        actually render into the frame.
RSpec.describe 'Organisations::NoteVersions', type: :request do
  let(:organisation) { create(:organisation) }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end

  let(:member) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    end
    u
  end

  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant(user, proj, **areas)
    create(:project_permission, { user: user, project: proj }.merge(areas))
  end

  # A note with two versions: the create callback makes v1, the content update makes v2.
  def note_with_two_versions
    ActsAsTenant.with_tenant(organisation) do
      note = create(:note, organisation: organisation, project: project, title: 'Versioned', content: '<div>first body</div>')
      note.update!(content: '<div>second body</div>')
      note
    end
  end

  describe 'GET index (history)' do
    it 'renders the version history for a readable note' do
      grant(member, project, notes_access: 'read_only')
      note = note_with_two_versions
      sign_in member

      get organisation_project_note_versions_path(organisation, project, note)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<turbo-frame') # rendered into the frame, not escaped
      expect(response.body).to include('note-version-history')
      expect(response.body).to include(I18n.t('views.organisations.note_versions.index.title'))
      # two versions → two history rows
      expect(response.body.scan('wiki-version-list__link').size).to eq(2)
    end
  end

  describe 'GET show (diff)' do
    it 'renders the unified diff of a version against its predecessor' do
      grant(member, project, notes_access: 'read_only')
      note = note_with_two_versions
      latest = note.note_versions.chronological.last
      sign_in member

      get organisation_project_note_version_path(organisation, project, note, latest)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('wiki-diff')
      # the changed line shows up (markdown of "second body")
      expect(response.body).to include('second body')
    end
  end

  describe 'SECURITY — access mirrors the note' do
    it 'is not found when the user cannot read the note' do
      grant(member, project, notes_access: 'no_access')
      note = note_with_two_versions
      sign_in member

      get organisation_project_note_versions_path(organisation, project, note)

      expect(response).to have_http_status(:not_found)
    end

    it 'requires authentication' do
      note = note_with_two_versions
      get organisation_project_note_versions_path(organisation, project, note)
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
