# frozen_string_literal: true

require 'rails_helper'

# Feinschliff B: does the object behind a citation still exist?
#
# A chat answer freezes the id of everything it drew on, and the source list builds
# its links from those frozen ids without a DB hit. That is right for the label and
# wrong for the LINK: a ticket deleted last week still got a link, and the click
# ended on an error page (in production not even a designed one — public/ is
# gitignored, so there is no 404 page there at all).
#
# The claim "gone" is only ever made on evidence: no organisation, no query, no
# claim. A wiring mistake therefore degrades to today's behaviour (a link that may
# 404), never to "every source of this answer is deleted".
RSpec.describe Lalabase::CitationTargets do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def ticket_cite(id)
    { 'type' => 'ticket', 'id' => id, 'project_id' => project.id, 'number' => 1, 'title' => 'X' }
  end

  def resolver(citations, org: organisation)
    described_class.for(citations: citations, organisation: org)
  end

  # Category 2: positive iteration over the whitelist. If a target type is missing
  # from MODEL_NAMES, it is NEVER asked about, and `gone?` then answers false
  # forever: deleted objects of this type keep their link and the click lands
  # on the error page. That is the quietest way to lose this safeguard.
  describe 'the model table' do
    # help_page is the one target outside the table, on purpose: Lalabase's own help belongs to
    # no organisation, and a page a release removes lands on /hilfe's own not-found page.
    it 'never asks for a help page, so it never calls one gone' do
      cite = { 'type' => 'help_page', 'source' => 'help', 'id' => 'guides/basics/tickets', 'title' => 'T' }

      expect(resolver([cite]).gone?(cite)).to be false
      expect(described_class::MODEL_NAMES).not_to have_key('help_page')
    end

    it 'knows a model for EVERY target the citation shapes can point at, the help aside' do
      Lalabase::Citations::CONTENT_TYPES.each do |type|
        citation = { 'type' => type, 'id' => 'x', 'ticket_id' => 'x', 'meeting_id' => 'x',
                     'project_id' => 'x', 'set_id' => 's', 'page' => 'p.md' }
        target = Lalabase::Citations.target_of(citation)

        expect(described_class::MODEL_NAMES).to have_key(target[:type]),
                                                "#{type} points at #{target[:type]}, which has no model here"
      end
    end

    # The other half: the name must point at a model that can also answer the
    # query. Without organisation_id, `where(organisation_id:)` raises.
    it 'names models that exist and can be scoped to an organisation' do
      described_class::MODEL_NAMES.each_value do |name|
        model = name.constantize

        expect(model.column_names).to include('organisation_id'),
                                      "#{name} cannot be filtered by organisation_id"
      end
    end

    it 'holds the table frozen, so nothing can add a type at runtime' do
      expect(described_class::MODEL_NAMES).to be_frozen
      expect(described_class::EMPTY).to be_frozen
    end
  end

  describe '#gone?' do
    it 'says no for a ticket that is still there, yes once it is deleted' do
      ticket = create(:ticket, project: project, organisation: organisation)
      cite = ticket_cite(ticket.id)

      expect(resolver([cite]).gone?(cite)).to be(false)

      ticket.destroy!

      expect(resolver([cite]).gone?(cite)).to be(true)
    end

    it 'follows a COMMENT to its ticket, not to the comment itself' do
      ticket = create(:ticket, project: project, organisation: organisation)
      post = create(:post, ticket: ticket, user: create(:user), organisation: organisation)
      cite = { 'type' => 'post', 'id' => post.id, 'ticket_id' => ticket.id,
               'project_id' => project.id, 'ticket_number' => 7 }

      expect(resolver([cite]).gone?(cite)).to be(false)

      # The comment survives, the ticket does not: the citation points at the
      # ticket, so this is gone even though the cited record still exists.
      ticket.destroy!

      expect(resolver([cite]).gone?(cite)).to be(true)
    end

    it 'follows a meeting analysis to its MEETING' do
      meeting = create(:meeting, project: project, organisation: organisation, creator: create(:user))
      cite = { 'type' => 'meeting_analysis', 'id' => 'a-1', 'meeting_id' => meeting.id,
               'project_id' => project.id, 'title' => 'Protokoll' }

      expect(resolver([cite]).gone?(cite)).to be(false)

      meeting.destroy!

      expect(resolver([cite]).gone?(cite)).to be(true)
    end

    it 'follows a time report to its project' do
      cite = { 'type' => 'time_report', 'id' => "#{project.id}:abc", 'project_id' => project.id,
               'title' => project.name, 'filters' => {} }

      expect(resolver([cite]).gone?(cite)).to be(false)

      # ONE citation, built once: asking about a different id than the one that was
      # resolved would land in the "never asked" branch and prove nothing.
      deleted_project = cite.merge('project_id' => SecureRandom.uuid)
      expect(resolver([deleted_project]).gone?(deleted_project)).to be(true)
    end

    # People S3: a contact points at its row, so a deleted row is gone like a deleted ticket.
    it 'follows a contact to its person row' do
      person = create(:person, organisation: organisation)
      cite = { 'type' => 'person', 'area' => 'people', 'id' => person.id, 'name' => person.name }

      expect(resolver([cite]).gone?(cite)).to be(false)

      person.destroy!

      expect(resolver([cite]).gone?(cite)).to be(true)
    end

    # A member points at the account, and an account has no organisation to scope it by.
    # Never asked, so never gone: a member who has left opens the plain people list, which
    # drops a member_id it cannot resolve (PeopleHelper#people_unresolved_lane_params).
    it 'never asks for a member, so a member is never called gone' do
      user_id = SecureRandom.uuid
      cite = { 'type' => 'person', 'area' => 'people', 'id' => user_id, 'member_id' => user_id, 'name' => 'X' }

      expect(Lalabase::Citations.target_of(cite)).to eq(type: 'member', id: user_id)
      expect(described_class::MODEL_NAMES).not_to have_key('member')
      expect(resolver([cite]).gone?(cite)).to be(false)
    end

    it 'never calls the code layer gone — it points at no record' do
      Lalabase::Citations::CODE_TYPES.each do |type|
        cite = { 'type' => type, 'id' => SecureRandom.uuid }
        expect(resolver([cite]).gone?(cite)).to be(false)
      end
    end

    it 'treats a ticket of ANOTHER organisation as gone (it is not reachable from here)' do
      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        create(:ticket, project: other_project, organisation: other_org)
      end
      cite = ticket_cite(foreign.id)

      # Flow anchor: the SAME id is present for its own organisation, so the
      # negative half below is about reach, not about a broken fixture.
      expect(described_class.for(citations: [cite], organisation: other_org).gone?(cite)).to be(false)
      expect(resolver([cite]).gone?(cite)).to be(true)
    end

    # Category 5: the resolver is HANDED its organisation. In the
    # streaming broadcast the ambient tenant belongs to whatever ran last, and
    # `require_tenant` is on: without its own with_tenant block the query would
    # find nothing there and EVERY source of the answer would be called "deleted".
    it 'resolves against the organisation it was GIVEN, not the ambient tenant' do
      ticket = create(:ticket, project: project, organisation: organisation)
      cite = ticket_cite(ticket.id)
      elsewhere = create(:organisation)

      ActsAsTenant.with_tenant(elsewhere) do
        expect(resolver([cite]).gone?(cite)).to be(false)
      end
    end

    it 'makes NO claim without an organisation' do
      ticket = create(:ticket, project: project, organisation: organisation)
      ticket_id = ticket.id
      ticket.destroy!
      cite = ticket_cite(ticket_id)

      expect(resolver([cite], org: nil).gone?(cite)).to be(false)
    end

    it 'makes NO claim about a citation it was never asked to resolve' do
      ticket = create(:ticket, project: project, organisation: organisation)
      ticket_id = ticket.id
      ticket.destroy!
      unasked = ticket_cite(ticket_id)

      # Built for a DIFFERENT citation: the deleted one was never queried, so the
      # resolver must not answer for it. Without this a wiring mistake would black
      # out every link in a transcript at once.
      expect(resolver([ticket_cite(create(:ticket, project: project, organisation: organisation).id)])
        .gone?(unasked)).to be(false)
    end

    it 'asks ONE query per type, not one per citation' do
      tickets = Array.new(3) { create(:ticket, project: project, organisation: organisation) }
      note = create(:note, project: project, organisation: organisation, creator: create(:user))
      cites = tickets.map { |t| ticket_cite(t.id) } +
              [{ 'type' => 'note', 'id' => note.id, 'project_id' => project.id, 'title' => 'N' }]

      count = count_queries { described_class.for(citations: cites, organisation: organisation) }

      expect(count).to eq(2)
    end
  end

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION|CACHE/)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
