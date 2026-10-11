# frozen_string_literal: true

require 'rails_helper'

# The edited view on the ticket list (doc/filterleiste_s1_s4_plan.md, S3a):
# same rule as spec/requests/organisations/knowledge_edited_view_spec.rb, on
# the other page the bar sits on. The ticket path goes through
# TicketSearchQuery, which must not apply the folder while the effective
# conditions are applied by apply_list_filters.
RSpec.describe 'Organisations::Tickets edited view', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:tickets_path) { organisation_project_tickets_path(organisation, project) }

  let!(:bug_ticket) { create_ticket('Bug ticket') }
  let!(:ui_ticket) { create_ticket('UI ticket') }
  let!(:plain_ticket) { create_ticket('Plain ticket') }

  let!(:folder) do
    ActsAsTenant.with_tenant(organisation) do
      folder = create(:smart_folder, name: 'Tagged', organisation: organisation, project: project,
                                     user: user, target_object_type: 'Ticket')
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'tag', operator: 'has_any_of', value: 'bug,ui')
      folder
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    tag_item(bug_ticket, 'bug')
    tag_item(ui_ticket, 'ui')
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def create_ticket(title)
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, title: title, project: project, organisation: organisation, creator: user)
    end
  end

  def tag_item(item, tag_name)
    tag = Tag.find_by(name: tag_name, organisation_id: organisation.id) ||
          create(:tag, name: tag_name, organisation: organisation)
    create(:tagging, tag: tag, taggable: item)
  end

  def rows
    response.body.scan(/data-ticket-id="([^"]+)"/).flatten.uniq
  end

  it 'applies the saved view as it is without edits' do
    get tickets_path, params: { smart_folder_id: folder.id }

    expect(rows).to contain_exactly(bug_ticket.id, ui_ticket.id)
  end

  it 'narrows when the address keeps fewer of the saved values' do
    get tickets_path, params: { smart_folder_id: folder.id, filter: { tag: ['bug'] } }

    expect(rows).to contain_exactly(bug_ticket.id)
  end

  it 'widens when the address adds a value to the saved category' do
    tag_item(plain_ticket, 'docs')
    get tickets_path, params: { smart_folder_id: folder.id, filter: { tag: %w[bug ui docs] } }

    expect(rows).to contain_exactly(bug_ticket.id, ui_ticket.id, plain_ticket.id)
  end

  it 'drops a saved category the reader emptied (filter_drop[])' do
    get tickets_path, params: { smart_folder_id: folder.id, filter_drop: ['tag'] }

    expect(rows).to contain_exactly(bug_ticket.id, ui_ticket.id, plain_ticket.id)
  end

  it 'keeps the intersection for a view with rules the bar cannot dissolve' do
    ActsAsTenant.with_tenant(organisation) do
      group = folder.smart_folder_rule_groups.first
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'title', operator: 'contains', value: 'ticket')
    end

    tag_item(plain_ticket, 'docs')
    get tickets_path, params: { smart_folder_id: folder.id, filter: { tag: %w[bug ui docs] } }

    expect(rows).to contain_exactly(bug_ticket.id, ui_ticket.id)
  end

  # The saved categories the reader did not touch stay in force. Every example
  # above edits the only saved category, so an effective set that ignored the
  # view altogether would pass them all; this one has a second saved category.
  it 'keeps the saved categories the reader did not touch' do
    ActsAsTenant.with_tenant(organisation) do
      group = folder.smart_folder_rule_groups.first
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'creator', operator: 'equals', value: user.id)
    end

    get tickets_path, params: { smart_folder_id: folder.id, filter_drop: ['creator'] }

    expect(rows).to contain_exactly(bug_ticket.id, ui_ticket.id)
  end

  it 'keeps the saved AND operator of a category the reader did not touch' do
    ActsAsTenant.with_tenant(organisation) do
      group = folder.smart_folder_rule_groups.first
      SmartFolderRule.where(smart_folder_rule_group: group).destroy_all
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'tag', operator: 'has_all_of', value: 'bug,ui')
    end
    tag_item(bug_ticket, 'ui')

    get tickets_path, params: { smart_folder_id: folder.id, filter: { creator: [user.id] } }

    expect(rows).to contain_exactly(bug_ticket.id)
  end

  it 'lets an edit win over a drop of the same category' do
    get tickets_path, params: { smart_folder_id: folder.id, filter_drop: ['tag'], filter: { tag: ['bug'] } }

    expect(rows).to contain_exactly(bug_ticket.id)
  end

  # filter_op of the wrong shape is no operator, not a 500. (filter[] of the
  # wrong shape still crashes in sort_params and the pagination helper, which
  # read params[:filter] on their own; that is older than this bar.)
  it 'answers an operator of the wrong shape with the list, not a 500' do
    get tickets_path, params: { smart_folder_id: folder.id, filter: { tag: ['bug'] }, filter_op: 'not' }

    expect(response).to have_http_status(:ok)
    expect(rows).to contain_exactly(bug_ticket.id)
  end
end
