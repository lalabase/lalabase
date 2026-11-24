# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the smart-folder form titles (edit/new, modal and page).
#
# Bug (2026-07-14): the edit modal always said "Ticket Filter bearbeiten" — even
# in the knowledge area, where the folder filters notes. The title keys were
# hardcoded to tickets although SmartFolder supports Note/Document/TimeSession/All.
#
# Contract pinned here: the form title is scoped to the folder's
# target_object_type, with a generic fallback for 'All'/unknown types.
RSpec.describe 'Organisations::SmartFolders Formular-Titel', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def folder_for(type)
    ActsAsTenant.with_tenant(organisation) do
      create(:smart_folder, user: user, organisation: organisation, project: project, target_object_type: type)
    end
  end

  describe 'GET #edit (Modal)' do
    it 'titelt einen Wissens-Filter nicht als Ticket-Filter' do
      get edit_organisation_smart_folder_path(organisation, folder_for('Note'), modal: true)

      expect(response.body).to include('Wissens-Filter bearbeiten')
      expect(response.body).not_to include('Ticket-Filter bearbeiten')
    end

    it 'titelt einen Ticket-Filter typbezogen' do
      get edit_organisation_smart_folder_path(organisation, folder_for('Ticket'), modal: true)

      expect(response.body).to include('Ticket-Filter bearbeiten')
    end

    it 'faellt bei target_object_type All auf den generischen Titel zurueck' do
      get edit_organisation_smart_folder_path(organisation, folder_for('All'), modal: true)

      expect(response.body).to include('Filter bearbeiten')
      expect(response.body).not_to include('Ticket-Filter bearbeiten')
    end
  end

  describe 'GET #new (Modal)' do
    it 'titelt per context_type (Wissen)' do
      get new_organisation_smart_folder_path(organisation, modal: true, context_type: 'Note', project_id: project.id)

      expect(response.body).to include('Neuer Wissens-Filter')
      expect(response.body).not_to include('Neuer Ticket-Filter')
    end

    it 'titelt generisch ohne context_type' do
      get new_organisation_smart_folder_path(organisation, modal: true, project_id: project.id)

      expect(response.body).to include('Neuer Filter')
      expect(response.body).not_to include('Neuer Ticket-Filter')
    end
  end

  # A saved filter is called a filter for every type (2026-11-24). The meeting
  # titles still said "Meeting-Ansicht" after the rename.
  describe 'the titles per type' do
    it 'call every type a filter, in both languages' do
      titles = %i[de en].flat_map do |locale|
        %w[new edit].flat_map do |mode|
          SmartFolder::SUPPORTED_OBJECT_TYPES.keys.filter_map do |type|
            I18n.t("smart_folders.#{mode}_title_by_type.#{type}", locale: locale, default: nil)
          end
        end
      end

      expect(titles.size).to be >= 20
      expect(titles).to all(match(/Filter/))
      expect(titles).to all(satisfy { |title| !title.match?(/Ansicht|\bview\b/i) })
    end
  end

  it 'calls the saved filter a filter in the column hint of the form' do
    %i[de en].each do |locale|
      hint = I18n.t('views.organisations.smart_folders.form.columns_chosen_in_list', locale: locale)

      expect(hint).to match(/Filter/i)
      expect(hint).not_to match(/Ansicht|\bview\b/i)
    end
  end
end
