# frozen_string_literal: true

require 'rails_helper'

# PE-B of the knowledge-filter rework: "Save as smart folder" adopts the type of
# the source page (target_object_type) and returns there (return_to).
RSpec.describe 'Organisations::SmartFolders create_from_filters', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def post_create(extra_params = {})
    post create_from_filters_organisation_smart_folders_path(organisation), params: {
      project_id: project.id,
      smart_folder_name: 'Mein Filter',
      filter: { tag: ['bug'] }
    }.merge(extra_params)
  end

  # The tenant is cleared by the middleware after the request — so model access
  # in assertions has to run inside the tenant context again.
  def folder_count
    ActsAsTenant.with_tenant(organisation) { SmartFolder.count }
  end

  def last_folder
    ActsAsTenant.with_tenant(organisation) { SmartFolder.order(:created_at).last }
  end

  # doc/spaltenwahl_plan.md, D6: a new ticket view starts with the reader's base
  # view columns of the project ("Alle Tickets" is the template) and stands alone
  # from then on; a later change of the base view does not reach it.
  it 'gives a new ticket view the reader base view columns of its own' do
    ActsAsTenant.with_tenant(organisation) do
      ViewConfiguration.create!(user: user, project: project, view_type: 'tickets', table_columns: %w[number title tags created_at])
    end

    post_create

    expect(last_folder.ordered_columns).to eq(%w[number title tags created_at])
    ActsAsTenant.with_tenant(organisation) { ViewConfiguration.for_user_project(user, project, 'tickets').update!(ordered_columns: %w[number title assignees]) }
    expect(last_folder.reload.ordered_columns).to eq(%w[number title tags created_at])
  end

  # The sanitizer lets the bar's special categories through by AdHocToSmartFolderService::SPECIAL_FIELDS
  # (plan §9, option A): a category missing there is dropped silently and the view saves without it.
  it 'saves the waiting states as rules' do
    post_create(filter: { waiting: ['true'], blocking: ['true'] }, filter_op: { blocking: 'not' })

    rules = ActsAsTenant.with_tenant(organisation) { last_folder.smart_folder_rule_groups.flat_map(&:smart_folder_rules) }
    expect(rules.map { |rule| [rule.field, rule.operator, rule.value] }).to contain_exactly(
      ['waiting', SmartFolders::Operators::IS, 'true'],
      ['blocking', SmartFolders::Operators::IS_NOT, 'true']
    )
  end

  it 'gives a note view no column list of its own' do
    post_create(target_object_type: 'Note', return_to: 'knowledge')

    expect(last_folder.ordered_columns).to be_nil
  end

  it 'creates a Ticket folder and returns to tickets without explicit type (Bestandsverhalten)' do
    expect { post_create }.to change { folder_count }.by(1)

    folder = last_folder
    expect(folder.target_object_type).to eq('Ticket')
    expect(response).to redirect_to(
      organisation_project_tickets_path(organisation_id: organisation.id, project_id: project.id,
                                        smart_folder_id: folder.id)
    )
  end

  it 'saves the active knowledge type filter as target_object_type and returns to knowledge' do
    post_create(target_object_type: 'Note', return_to: 'knowledge')

    folder = last_folder
    expect(folder.target_object_type).to eq('Note')
    expect(response).to redirect_to(
      organisation_project_knowledge_index_path(organisation_id: organisation.id, project_id: project.id,
                                                smart_folder_id: folder.id)
    )
  end

  it 'saves All for the knowledge "Alles" type filter' do
    post_create(target_object_type: 'All', return_to: 'knowledge')

    expect(last_folder.target_object_type).to eq('All')
  end

  # S7: the bar derives the target from the type condition and sends it as a
  # form field; a knowledge save without one is a folder of all types.
  it 'falls back to All for a knowledge save without a target' do
    post_create(return_to: 'knowledge', target_object_type: nil)
    expect(last_folder.target_object_type).to eq('All')
  end

  it 'falls back to Ticket for non-whitelisted target types' do
    post_create(target_object_type: 'User')

    expect(last_folder.target_object_type).to eq('Ticket')
  end

  # A folder without rules matches nothing, for good. The bar sends a type
  # condition as the target, not as a rule, so "Typ: Notiz" alone arrives as
  # an empty set: refused, back to the list with the alert, no folder.
  it 'refuses an empty set (a type condition alone) instead of creating a folder that matches nothing' do
    expect { post_create(filter: { tag: [''] }, target_object_type: 'Note', return_to: 'knowledge') }
      .not_to(change { folder_count })

    expect(response).to redirect_to(organisation_project_knowledge_index_path(organisation_id: organisation.id, project_id: project.id))
    expect(flash[:alert]).to eq(I18n.t('flash.smart_folders.create_from_filters_error'))
  end

  it 'converts creator filters into creator rules (frueher uebersprungen)' do
    post_create(filter: { creator: [user.id] }, target_object_type: 'Note', return_to: 'knowledge')

    rules = ActsAsTenant.with_tenant(organisation) do
      last_folder.smart_folder_rule_groups.sole.smart_folder_rules.to_a
    end
    expect(rules.sole).to have_attributes(field: 'creator', operator: 'equals', value: user.id)
  end
  it 'refuses a view with more combinations than a view may hold and says why' do
    ids = Array.new(8) { SecureRandom.uuid }
    expect { post_create(filter: { creator: ids, assignee: ids.reverse }) }.not_to(change { folder_count })
    expect(flash[:alert]).to eq(I18n.t('activerecord.errors.models.smart_folder.too_many_rule_groups', count: SmartFolder::MAX_RULE_GROUPS))
  end
end
