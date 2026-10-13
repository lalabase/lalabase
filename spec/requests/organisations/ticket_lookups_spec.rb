# frozen_string_literal: true

require 'rails_helper'

# The ticket search behind the "Link" modal (doc/ticket_relations_plan.md, revision 4, §4 and
# §7). It crosses projects, so it is a door into projects the searcher cannot see unless it
# runs over policy_scope(Ticket). It searches number and TITLE only: a match on the text of a
# comment would tell the searcher what a private comment says.
RSpec.describe 'Organisations::TicketLookups', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:readable_project) { new_project(organisation, 'Kundenportal') }
  let(:second_readable_project) { new_project(organisation, 'Backoffice') }
  let(:hidden_project) { new_project(organisation, 'Vorstand') }

  let(:user) { member_reading(readable_project, second_readable_project) }

  let!(:shown) { new_ticket(readable_project, 'Login bug on the portal') }
  let!(:readable_match) { new_ticket(readable_project, 'Login page redesign') }
  let!(:elsewhere_match) { new_ticket(second_readable_project, 'Login audit') }
  let!(:hidden_match) { new_ticket(hidden_project, 'Login secrets rotation') }

  def new_project(org, name)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org, name: name) }
  end

  def new_ticket(project, title)
    ActsAsTenant.with_tenant(project.organisation) { create(:ticket, project: project, title: title) }
  end

  def member_reading(*projects)
    member = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation)
      create(:membership, user: member, organisation: organisation, role: role, active: true)
      projects.each { |project| create(:project_permission, user: member, project: project, tickets_access: 'read_only') }
    end
    member
  end

  def lookup(params = {})
    get organisation_ticket_lookups_path(organisation), params: params, as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch('options')
  end

  def values(options)
    options.pluck('value')
  end

  before { sign_in user }

  it 'finds readable tickets by title across projects, with number and project' do
    options = lookup(q: 'login')

    expect(values(options)).to include(readable_match.id, elsewhere_match.id)
    option = options.find { |entry| entry['value'] == elsewhere_match.id }
    expect(option['text']).to eq("##{elsewhere_match.number} Login audit")
    expect(option['detail']).to eq('Backoffice')
  end

  it 'never returns a ticket from a project the user cannot read' do
    options = lookup(q: 'login')

    # The search found matches, so the missing one is the rule and not an empty answer.
    expect(values(options)).to include(readable_match.id)
    expect(values(options)).not_to include(hidden_match.id)
    expect(response.body).not_to include('Login secrets rotation', 'Vorstand', hidden_match.id)
  end

  it 'never returns a ticket of another organisation' do
    foreign_organisation = create(:organisation)
    foreign = new_ticket(new_project(foreign_organisation, 'Fremd'), 'Login elsewhere')

    options = lookup(q: 'login')

    expect(values(options)).to include(readable_match.id)
    expect(values(options)).not_to include(foreign.id)
  end

  it 'leaves out the ticket the modal is open on' do
    options = lookup(q: 'login', exclude: shown.id)

    expect(values(options)).to include(readable_match.id)
    expect(values(options)).not_to include(shown.id)
  end

  it 'finds a ticket by its number, with or without the hash' do
    expect(values(lookup(q: readable_match.number.to_s))).to include(readable_match.id)
    expect(values(lookup(q: "##{readable_match.number}"))).to include(readable_match.id)
  end

  it 'finds by number only in readable projects' do
    options = lookup(q: hidden_match.number.to_s)

    expect(values(options)).not_to include(hidden_match.id)
  end

  it 'searches the title only, not the text of comments' do
    ActsAsTenant.with_tenant(organisation) do
      create(:post, ticket: readable_match, user: user, organisation: organisation,
                    content: 'Kuendigungsfrist', is_private: true, visible_to_user_id: create(:user, organisation: organisation).id)
    end

    expect(lookup(q: 'Kuendigungsfrist')).to be_empty
  end

  it 'answers an empty search with no options' do
    expect(lookup(q: '')).to be_empty
    expect(lookup(q: '   ')).to be_empty
    expect(lookup).to be_empty
  end

  it 'returns at most 20 options' do
    ActsAsTenant.with_tenant(organisation) do
      Prosopite.pause { create_list(:ticket, 22, project: readable_project, title: 'Stapel ticket') }
    end

    expect(lookup(q: 'stapel').size).to eq(20)
  end

  # Typed into a search field, character by character: none of it may reach PostgreSQL as
  # tsquery syntax (the raw term in to_tsquery raises a syntax error) or as SQL (#889).
  ['foo:', '(', '!', "'", 'a & b | c', ':*', "login' OR '1'='1", ':search', '\\', '99999999999999999999'].each do |term|
    it "answers #{term.inspect} without an error" do
      expect { lookup(q: term) }.not_to raise_error
    end
  end

  it 'ignores a q that is not a string' do
    expect(lookup(q: ['login'])).to be_empty
  end

  it 'refuses a signed-out visitor' do
    sign_out user
    get organisation_ticket_lookups_path(organisation), params: { q: 'login' }, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(response.body).not_to include('Login page redesign')
  end
end
