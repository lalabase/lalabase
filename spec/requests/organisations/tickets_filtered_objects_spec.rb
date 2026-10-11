# frozen_string_literal: true

require 'rails_helper'

# What: the one owner of the filtered ticket list, ObjectListController#filtered_objects
#   (doc/ticket_bulk_edit_plan.md, S0).
# Type: request spec against the index, pinning the hit count and the rows the
#   table shows for four shapes of address.
# Why: index paginates filtered_objects, and the bulk action of slice 2 resolves
#   "alle Treffer" from the same method. These four addresses are the ones that
#   spec will send; the numbers here are what the table showed, so the two can
#   be compared and can never drift apart unnoticed.
RSpec.describe 'Ticket list filtered objects', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:tickets_path) { organisation_project_tickets_path(organisation, project) }

  let!(:bug_ticket) { create_ticket('Bug in the export') }
  let!(:ui_ticket) { create_ticket('UI polish') }
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

  def hits
    response.body[/data-fb-hits-total="(\d+)"/, 1].to_i
  end

  it 'shows every ticket of the project without an address' do
    get tickets_path

    expect(hits).to eq(3)
    expect(rows).to contain_exactly(bug_ticket.id, ui_ticket.id, plain_ticket.id)
  end

  it 'shows the folder as saved' do
    get tickets_path, params: { smart_folder_id: folder.id }

    expect(hits).to eq(2)
    expect(rows).to contain_exactly(bug_ticket.id, ui_ticket.id)
  end

  it 'shows the edited folder by its effective conditions' do
    get tickets_path, params: { smart_folder_id: folder.id, filter: { tag: ['bug'] } }

    expect(hits).to eq(1)
    expect(rows).to contain_exactly(bug_ticket.id)
  end

  it 'shows a title search' do
    get tickets_path, params: { search: 'Bug', search_mode: 'title_only' }

    expect(hits).to eq(1)
    expect(rows).to contain_exactly(bug_ticket.id)
  end

  it 'shows a title search narrowed by a condition' do
    get tickets_path, params: { search: 'i', search_mode: 'title_only', filter: { tag: ['ui'] } }

    expect(hits).to eq(1)
    expect(rows).to contain_exactly(ui_ticket.id)
  end
end
