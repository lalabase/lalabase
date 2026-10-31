# frozen_string_literal: true

require 'rails_helper'

# The relations section and the waiting hint on the ticket page (doc/ticket_relations_plan.md,
# revision 4, §4, §8.1, §8.2), rendered through the real show route.
#
# The security half: a relation to a ticket in a project the reader cannot see appears nowhere,
# while the waiting hint still counts it, as "without access" and with no title, number or
# project. Every negative assertion runs on a page this example proves present.
RSpec.describe 'Ticket relations section and waiting hint', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { new_project('Kundenportal') }
  let(:other_project) { new_project('Backoffice') }
  let(:hidden_project) { new_project('Vorstand') }

  let(:writer) { member(project => 'read_write', other_project => 'read_only') }
  let(:reader) { member(project => 'read_only', other_project => 'read_only') }

  let(:ticket) { new_ticket(project, 'Checkout breaks') }

  let(:rs) { 'views.organisations.tickets.shared.relations' }

  before do
    [project, other_project, hidden_project].each { |p| status_field(p) }
  end

  after { ActsAsTenant.current_tenant = nil }

  def new_project(name)
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: name) }
  end

  def status_field(project)
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                           options: { 'allowed_values' => [
                                             { 'value' => 'offen', 'labels' => { 'de' => 'Offen', 'en' => 'Open' },
                                               'system_functions' => ['is_new'] },
                                             { 'value' => 'erledigt', 'labels' => { 'de' => 'Erledigt', 'en' => 'Done' },
                                               'system_functions' => ['is_completed'] }
                                           ] })
    end
  end

  def new_ticket(project, title, status: 'offen', **attributes)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, title: title, custom_attributes: { 'status' => status }, **attributes)
      end
    end
  end

  def member(access)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      access.each { |p, level| create(:project_permission, user: user, project: p, tickets_access: level) }
    end
    user
  end

  def link(source, target, type, delay_days: nil)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: type, delay_days: delay_days)
      end
    end
  end

  def show(as: writer, of: ticket)
    sign_in as
    get organisation_project_ticket_path(organisation, of.project, of)
    expect(response).to have_http_status(:ok)
    response.body
  end

  def section
    Nokogiri::HTML(response.body).at_css("section#ticket-relations-#{ticket.id}")
  end

  def hint
    Nokogiri::HTML(response.body).at_css("#ticket-waiting-#{ticket.id}")
  end

  # Review round 4 of #944: a native #anchor pushed a history entry, and Back then reloaded
  # the lane (losing a comment draft) and carried the hash into later addresses. A button
  # scrolls to the section instead, with no address and no history.
  def expect_jump_to_section
    jump = hint.at_css('button[data-controller="scroll-into-view"]')
    expect(jump['data-scroll-into-view-target-value']).to eq("ticket-relations-#{ticket.id}")
    expect(jump['type']).to eq('button')
    expect(hint.at_css('a[href^="#"]')).to be_nil
  end

  def rows(group)
    section.css(%([data-relation-group="#{group}"] li))
  end

  describe 'the section' do
    it 'groups the relations from this ticket\'s side, in the fixed order' do
      link(new_ticket(other_project, 'Payment switch'), ticket, :blocks)
      link(ticket, new_ticket(project, 'Release notes'), :precedes, delay_days: 3)
      link(new_ticket(project, 'Old checkout'), ticket, :relates_to)
      link(new_ticket(project, 'Checkout broken (dup)'), ticket, :duplicates)

      show

      groups = section.css('[data-relation-group]').map { |node| node['data-relation-group'] }
      expect(groups).to eq(%w[waiting_on holding_up related duplicates])
      expect(rows('waiting_on').text).to include(I18n.t("#{rs}.kinds.blocked_by"), 'Payment switch', 'Backoffice')
      expect(rows('holding_up').text).to include(I18n.t("#{rs}.kinds.precedes"), 'Release notes',
                                                 I18n.t("#{rs}.delay", count: 3, days: '+3'))
      expect(rows('related').text).to include(I18n.t("#{rs}.kinds.relates_to"), 'Old checkout')
      expect(rows('duplicates').text).to include(I18n.t("#{rs}.kinds.duplicated_by"), 'Checkout broken (dup)')
    end

    it 'shows the project only for a ticket of another project, and a delay only when it is not zero' do
      same = new_ticket(project, 'Same project follower')
      link(ticket, same, :precedes, delay_days: 0)
      link(ticket, new_ticket(other_project, 'Elsewhere'), :relates_to)

      show

      expect(rows('holding_up').first.text).not_to include('Kundenportal')
      expect(rows('holding_up').first.text).not_to match(/[+-]\d+ /)
      expect(rows('related').first.text).to include('Backoffice')
    end

    it 'shows the status of the other ticket and puts done ones last, marked' do
      done = new_ticket(project, 'Done blocker', status: 'erledigt')
      open = new_ticket(project, 'Open blocker')
      link(done, ticket, :blocks)
      link(open, ticket, :blocks)

      show

      titles = rows('waiting_on').map { |row| row.at_css('a').text.strip }
      expect(titles).to eq(['Open blocker', 'Done blocker'])
      expect(rows('waiting_on').last['data-relation-done']).not_to be_nil
      expect(rows('waiting_on').first['data-relation-done']).to be_nil
      expect(rows('waiting_on').last.text).to include('Erledigt')
    end

    it 'keeps a link into the same project in the ticket frame and sends one into another project to the top' do
      same = new_ticket(project, 'Same project')
      elsewhere = new_ticket(other_project, 'Other project')
      link(ticket, same, :relates_to)
      link(ticket, elsewhere, :blocks)

      show

      same_link = section.at_css(%(a[href="#{organisation_project_tickets_path(organisation, project, ticket_id: same.id)}"]))
      other_link = section.at_css(%(a[href="#{organisation_project_tickets_path(organisation, other_project, ticket_id: elsewhere.id)}"]))
      expect(same_link['data-turbo-frame']).to be_nil
      expect(other_link['data-turbo-frame']).to eq('_top')
      expect(same_link.key?('data-ticket-link')).to be(true)
    end

    it 'renders for a sub-task as well' do
      child = new_ticket(project, 'Child task', parent: ticket)
      link(new_ticket(project, 'Blocks the child'), child, :blocks)

      body = show(of: child)

      expect(body).to include("ticket-relations-#{child.id}", 'Blocks the child')
    end

    it 'is an empty, hidden container without relations, beside the empty modal frame' do
      show

      expect(section).not_to be_nil
      expect(section['class']).to include('hidden')
      expect(section.text.strip).to be_empty
      expect(hint).not_to be_nil
      expect(hint['class']).to include('hidden')
      expect(response.body).to include(%(<turbo-frame id="ticket-relation-modal-#{ticket.id}">))
    end
  end

  describe 'who sees what' do
    let(:hidden) { new_ticket(hidden_project, 'Board decision on budget', number: 4711) }

    it 'leaves out a relation to a ticket the reader cannot see, and names it nowhere' do
      link(hidden, ticket, :blocks)
      link(ticket, new_ticket(project, 'Visible neighbour'), :relates_to)

      body = show

      # The page and the section are there: the visible relation proves it.
      expect(section.text).to include('Visible neighbour')
      expect_absent(body, 'Board decision on budget', 'Vorstand', hidden.id, 4711)
    end

    it 'still counts that blocker in the hint, as one without access' do
      link(hidden, ticket, :blocks)

      body = show

      expect(hint.text.squish).to eq(I18n.t("#{rs}.hint.hidden", count: 1))
      expect_absent(body, 'Board decision on budget', 'Vorstand', hidden.id, 4711)
    end

    it 'counts readable and hidden blockers together, naming the hidden share' do
      link(hidden, ticket, :blocks)
      link(new_ticket(other_project, 'Readable blocker'), ticket, :precedes)

      body = show

      expect(hint.text.squish).to eq(I18n.t("#{rs}.hint.mixed", count: 2, hidden: 1))
      expect_jump_to_section
      expect(body).not_to include('Board decision on budget', hidden.id)
    end

    it 'offers remove, "+ Link" and the menu entry to a writer' do
      link(ticket, new_ticket(project, 'Neighbour'), :relates_to)
      new_path = new_organisation_project_ticket_relation_path(organisation, project, ticket)

      body = show(as: writer)

      expect(section.css('form[method="post"] input[name="_method"][value="delete"]').size).to eq(1)
      expect(body.scan(%(href="#{new_path}")).size).to eq(2)
    end

    it 'offers none of it to a reader, who still sees the relations' do
      link(ticket, new_ticket(project, 'Neighbour'), :relates_to)

      body = show(as: reader)

      expect(section.text).to include('Neighbour')
      expect(section.css('input[name="_method"][value="delete"]')).to be_empty
      expect(body).not_to include(new_organisation_project_ticket_relation_path(organisation, project, ticket))
    end
  end

  describe 'the waiting hint' do
    it 'names a single readable blocker as a link' do
      blocker = new_ticket(other_project, 'Payment switch')
      link(blocker, ticket, :blocks)

      show

      expect(hint.text.squish).to eq(I18n.t("#{rs}.hint.single_html", ticket: blocker.display_title))
      expect(hint.at_css('a')['href']).to eq(organisation_project_tickets_path(organisation, other_project, ticket_id: blocker.id))
      expect(hint.at_css('a')['data-turbo-frame']).to eq('_top')
    end

    it 'counts several readable blockers and jumps to the section' do
      link(new_ticket(project, 'First'), ticket, :blocks)
      link(new_ticket(other_project, 'Second'), ticket, :precedes)

      show

      expect(hint.text.squish).to eq(I18n.t("#{rs}.hint.several", count: 2))
      expect_jump_to_section
    end

    it 'counts a blocker linked twice as one ticket, while the section shows both relations' do
      blocker = new_ticket(project, 'Twice')
      link(blocker, ticket, :blocks)
      link(blocker, ticket, :precedes)

      show

      expect(hint.text.squish).to eq(I18n.t("#{rs}.hint.single_html", ticket: blocker.display_title))
      expect(rows('waiting_on').size).to eq(2)
    end

    it 'says nothing when the blocker is done, or the ticket itself is' do
      link(new_ticket(project, 'Done blocker', status: 'erledigt'), ticket, :blocks)

      show
      expect(section.text).to include('Done blocker')
      expect(hint['class']).to include('hidden')

      done_ticket = new_ticket(project, 'Done waiter', status: 'erledigt')
      link(new_ticket(project, 'Open blocker'), done_ticket, :blocks)
      show(of: done_ticket)
      expect(Nokogiri::HTML(response.body).at_css("#ticket-waiting-#{done_ticket.id}")['class']).to include('hidden')
    end

    it 'says nothing for relations that make nobody wait' do
      link(ticket, new_ticket(project, 'Waits on this one'), :blocks)
      link(new_ticket(project, 'Just related'), ticket, :relates_to)

      show

      expect(section.text).to include('Waits on this one')
      expect(hint['class']).to include('hidden')
    end
  end

  # Plan §12: no N+1 with three relations in two projects. Prosopite scans every example; this
  # one makes sure there is something to repeat.
  it 'renders three relations in two projects without an N+1' do
    link(new_ticket(project, 'One'), ticket, :blocks)
    link(new_ticket(other_project, 'Two'), ticket, :precedes)
    link(ticket, new_ticket(other_project, 'Three'), :relates_to)

    show

    expect(section.css('li').size).to eq(3)
  end
end
