# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Organisations::OrganisationSettings', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  let!(:member_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member, organisation: organisation, role: member_role, active: true)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe 'GET /org/:organisation_id/settings' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns success' do
        get organisation_settings_path(organisation)
        expect(response).to have_http_status(:success)
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'denies access and redirects' do
        get organisation_settings_path(organisation)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        get organisation_settings_path(organisation)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'PATCH /org/:organisation_id/settings' do
    context 'as admin' do
      before { sign_in admin }

      it 'updates the organisation and redirects' do
        patch organisation_settings_path(organisation), params: {
          organisation: { name: 'Neuer Name' }
        }
        expect(response).to redirect_to(organisation_settings_path(organisation))
        expect(organisation.reload.name).to eq('Neuer Name')
      end

      it 'renders show on validation error' do
        patch organisation_settings_path(organisation), params: {
          organisation: { name: '' }
        }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'denies access and redirects' do
        patch organisation_settings_path(organisation), params: {
          organisation: { name: 'Hacked' }
        }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
        expect(organisation.reload.name).not_to eq('Hacked')
      end
    end
  end

  describe 'the inbox project' do
    let!(:project) { create(:project, organisation: organisation, name: 'Eingangskorb') }
    let!(:archived) { create(:project, organisation: organisation, name: 'Altbestand', archived_at: 1.day.ago) }

    before { sign_in admin }

    it 'sets and clears the project' do
      patch organisation_settings_path(organisation), params: { organisation: { meeting_inbox_project_id: project.id } }
      expect(organisation.reload.meeting_inbox).to eq(project)

      patch organisation_settings_path(organisation), params: { organisation: { meeting_inbox_project_id: '' } }
      expect(organisation.reload.meeting_inbox_project_id).to be_nil
    end

    it 'refuses a project of another organisation and stores nothing' do
      foreign = ActsAsTenant.without_tenant { create(:project, organisation: create(:organisation)) }

      patch organisation_settings_path(organisation), params: { organisation: { meeting_inbox_project_id: foreign.id } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(organisation.reload.meeting_inbox_project_id).to be_nil
    end

    it 'refuses an archived project and stores nothing' do
      patch organisation_settings_path(organisation), params: { organisation: { meeting_inbox_project_id: archived.id } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(organisation.reload.meeting_inbox_project_id).to be_nil
    end

    it 'keeps an inbox archived meanwhile when the form is saved with it, and says so' do
      organisation.update!(meeting_inbox_project: project)
      project.archive!(admin)

      get organisation_settings_path(organisation)
      expect(response.body).to include(I18n.t('organisations.organisation_settings.show.meeting_inbox_archived_hint'))
      expect(response.body).to include(I18n.t('organisations.organisation_settings.show.meeting_inbox_archived_option', name: project.name))

      patch organisation_settings_path(organisation), params: { organisation: { name: 'Neu', meeting_inbox_project_id: project.id } }
      expect(organisation.reload.meeting_inbox_project_id).to eq(project.id)
    end

    it 'marks the inbox on its dashboard and no other project there' do
      organisation.update!(meeting_inbox_project: project)
      other = create(:project, organisation: organisation, name: 'Anderes')
      subtitle = I18n.t('organisations.projects.show.meeting_inbox_subtitle', name: project.name)

      get organisation_project_path(organisation, project)
      expect(response.body).to include(CGI.escapeHTML(subtitle))
      expect(response.body).to include(%(aria-label="#{I18n.t('navigation.meeting_inbox')}"))

      get organisation_project_path(organisation, other)
      expect(response.body).not_to include(CGI.escapeHTML(subtitle))
    end
  end
end
