# frozen_string_literal: true

require 'rails_helper'

# The activity tool (assistant plan §9a Befund 1, §13-11). The gate itself is
# tested in Activities::VisibleTo; what is tested here is the PAYLOAD, because
# that is what reaches the model: which fields travel, which deliberately do not,
# and whether the numbers next to a shortened list still cover everything.
RSpec.describe Lalabase::Tools::RecentActivity do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation, name: 'Nordlicht Software') }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    create(:project_permission, user: user, project: project,
                                tickets_access: 'read_only', notes_access: 'read_only')
  end

  after { ActsAsTenant.current_tenant = nil }

  let(:scope) { Lalabase::Tools::Scope.new(organisation: organisation, actor: user) }
  let(:context) { Lalabase::Tools::Context.new(project: nil, actor: user, organisation: organisation, scope: scope) }

  def ticket_event(key: 'ticket.created', at: 1.hour.ago, parameters: {}, ticket: nil)
    ticket ||= create(:ticket, project: project, organisation: organisation, title: 'Durchmesser prüfen')
    create(:activity, trackable: ticket, organisation: organisation, actor: user,
                      key: key, action: key.split('.').last, parameters: parameters, created_at: at)
  end

  def project_event(key:, parameters: {}, at: 1.hour.ago)
    create(:activity, trackable: project, organisation: organisation, actor: user,
                      key: key, action: key.split('.').last, parameters: parameters, created_at: at)
  end

  def payload(args = {})
    JSON.parse(described_class.execute(args: args, context: context).content)
  end

  describe 'the shape of an event' do
    it 'names when, who, what kind, which project and a subject' do
      ticket_event

      event = payload['events'].first

      expect(event['key']).to eq('ticket.created')
      expect(event['actor']).to eq(user.full_name)
      expect(event.dig('project', 'name')).to eq('Nordlicht Software')
      expect(event['subject']).to include('Durchmesser prüfen')
      expect { Time.iso8601(event['at']) }.not_to raise_error
    end

    # The parameters are a snapshot from the moment of the event. A ticket renamed
    # since would otherwise be reported under its old name.
    it 'takes a ticket subject from the record, not from the frozen parameters' do
      ticket = create(:ticket, project: project, organisation: organisation, title: 'Neuer Titel')
      ticket_event(ticket: ticket, parameters: { 'display_name' => 'Alter Titel' })

      expect(payload['events'].first['subject']).to include('Neuer Titel')
      expect(payload['events'].first['subject']).not_to include('Alter Titel')
    end

    it 'takes a project-tracked subject from the whitelisted parameter' do
      project_event(key: 'project.note_created',
                    parameters: { 'note_title' => 'Protokoll Kickoff', 'creator_name' => 'Wer auch immer' })

      expect(payload['events'].first['subject']).to eq('Protokoll Kickoff')
    end
  end

  # ⚠️ The reason SUBJECT_FIELDS is a whitelist rather than a pass-through.
  describe 'what deliberately never reaches the prompt' do
    # ⚠️ This example carries ONLY the forbidden field, and that is what makes it
    # bite. Two mutation probes were needed to get here: with a harmless field
    # beside it, replacing the whitelist by a plain `parameters.values.first`
    # still picked the harmless one -- and ordering the hash does not help
    # either, because jsonb hands keys back sorted by length, not in insertion
    # order. With nothing else to pick, only the whitelist keeps the address out.
    it 'omits an e-mail address that is the only thing the parameters carry' do
      ProjectPermission.find_by(user: user, project: project).update!(members_access: 'read_only')
      project_event(key: 'project.member_removed', parameters: { 'user_email' => 'geheim@example.com' })

      content = described_class.execute(args: {}, context: context).content
      expect(content).not_to include('geheim@example.com')
      expect(JSON.parse(content)['events'].first).not_to have_key('subject')
    end

    it 'still names the member by the whitelisted field when one is there' do
      # members_access on purpose: without it the gate drops the row before the
      # payload is built, and the example would pass without testing anything.
      ProjectPermission.find_by(user: user, project: project).update!(members_access: 'read_only')
      project_event(key: 'project.member_added',
                    parameters: { 'user_email' => 'geheim@example.com', 'tickets_access' => 'write',
                                  'user_name' => 'Neue Person' })

      content = described_class.execute(args: {}, context: context).content
      expect(content).not_to include('geheim@example.com')
      expect(content).to include('Neue Person')
    end

    # Defence in depth rather than the load-bearing rule, and worth saying so:
    # `post_excerpt` only ever occurs on ticket.post_added, and a ticket row takes
    # its subject from the RECORD without looking at parameters at all. Two
    # independent things keep the comment text out; this pins the outcome.
    it 'omits the excerpt of a comment, which carries its own privacy' do
      ticket_event(key: 'ticket.post_added',
                   parameters: { 'post_excerpt' => 'GEHEIMER KOMMENTARTEXT', 'display_name' => 'Ticket' })

      expect(described_class.execute(args: {}, context: context).content).not_to include('GEHEIMER KOMMENTARTEXT')
    end
  end

  describe 'the window' do
    it 'defaults to the last seven days' do
      inside = ticket_event(at: 2.days.ago)
      ticket_event(at: 9.days.ago)

      expect(payload['days']).to eq(7)
      expect(payload['events'].map { |e| e['key'] }.size).to eq(1)
      expect(payload['total']).to eq(1)
      expect(inside).to be_present
    end

    it 'takes a wider window when asked' do
      ticket_event(at: 9.days.ago)

      expect(payload(days: 30)['total']).to eq(1)
    end

    it 'clamps an absurd window to the maximum instead of refusing' do
      ticket_event

      expect(payload(days: 100_000)['days']).to eq(described_class::MAX_DAYS)
    end

    it 'falls back to the default for a nonsensical value' do
      ticket_event

      expect(payload(days: 0)['days']).to eq(described_class::DEFAULT_DAYS)
      expect(payload(days: -5)['days']).to eq(described_class::DEFAULT_DAYS)
    end
  end

  describe 'the cap and the count' do
    # Boundary around the cap: n-1 / n / n+1. The count has to stay complete even
    # when the list is shortened, otherwise a partial list reads as the answer.
    before { stub_const("#{described_class}::MAX_LIMIT", 3) }

    it 'reports every row it shows when there are fewer than the cap' do
      2.times { |i| ticket_event(at: (i + 1).hours.ago) }

      expect(payload(limit: 3)).to include('total' => 2, 'shown' => 2, 'truncated' => false)
    end

    it 'is not truncated exactly at the cap' do
      3.times { |i| ticket_event(at: (i + 1).hours.ago) }

      expect(payload(limit: 3)).to include('total' => 3, 'shown' => 3, 'truncated' => false)
    end

    it 'says so one above the cap, and keeps the total complete' do
      4.times { |i| ticket_event(at: (i + 1).hours.ago) }

      expect(payload(limit: 99)).to include('total' => 4, 'shown' => 3, 'truncated' => true)
    end
  end

  describe 'reach and citations' do
    it 'cites the tickets it names, so the chips lead somewhere' do
      ticket_event

      result = described_class.execute(args: {}, context: context)

      expect(result.citations.map { |c| c[:type] }).to all(eq('ticket'))
      expect(result.citations.first[:area]).to eq('tickets')
    end

    it 'carries the L7 coverage of the call' do
      ticket_event

      expect(described_class.execute(args: {}, context: context).coverage).to include(:searched, :total)
    end

    it 'answers an empty window without pretending to have looked nowhere' do
      result = described_class.execute(args: {}, context: context)

      expect(result.kind).to eq(:empty)
      expect(result.coverage).to include(:searched)
    end

    # A single-project call has no Context#scope, and every row lookup in here
    # goes through it.
    it 'refuses a call without org-wide reach instead of raising' do
      single = Lalabase::Tools::Context.new(project: project, actor: user, organisation: organisation)

      expect(described_class.execute(args: {}, context: single).error).to be_present
    end
  end

  # ⚠️ The number under the answer, and not a detail: MessageComponent renders
  # "Durchsucht: N von M Projekten" from it, deterministically, and that sentence
  # means "your rights stopped here". This feed spans every area, so a coverage
  # taken from the :tickets area alone describes the wrong reach -- measured
  # before the fix: an answer out of three projects labelled "0 von 3".
  describe 'the coverage of an answer that spans areas' do
    # Two more projects the asker may read NOTES in and tickets nowhere, plus one
    # they may not read at all so `searched` has something to be smaller than.
    def notes_only_projects(count = 2, with_event: true)
      Array.new(count) do |i|
        create(:project, organisation: organisation, name: "Notizprojekt #{i}").tap do |p|
          create(:project_permission, user: user, project: p,
                                      notes_access: 'read_only', tickets_access: 'no_access')
          next unless with_event

          create(:activity, trackable: p, organisation: organisation, actor: user,
                            key: 'project.note_created', action: 'note_created',
                            parameters: { 'note_title' => "Notiz #{i}" })
        end
      end
    end

    it 'counts every project the answer drew on, not just the tickets area' do
      ticket_event
      notes_only_projects
      create(:project, organisation: organisation, name: 'Unerreichbar')

      result = described_class.execute(args: {}, context: context)
      answered_from = JSON.parse(result.content)['events'].map { |e| e.dig('project', 'id') }.uniq

      # Three projects in the answer, four in the organisation. Taking the number
      # from :tickets would say 1 here.
      expect(answered_from.size).to eq(3)
      expect(result.coverage).to eq({ searched: 3, total: 4 })
    end

    # The sharpest form of the same defect: the asker may read NO tickets
    # anywhere, so the :tickets reach is empty while the answer is not.
    it 'does not report zero for a reader who may read no tickets at all' do
      ProjectPermission.find_by(user: user, project: project).update!(tickets_access: 'no_access')
      notes_only_projects
      project_event(key: 'project.note_created', parameters: { 'note_title' => 'Protokoll' })

      result = described_class.execute(args: {}, context: context)

      expect(JSON.parse(result.content)['events']).not_to be_empty
      expect(result.coverage[:searched]).to eq(3)
    end

    # An empty answer reports the same reach as a full one: the coverage says how
    # far it LOOKED, not how much it found.
    it 'reports the same reach when the window is empty' do
      notes_only_projects(with_event: false)

      result = described_class.execute(args: {}, context: context)

      expect(result.kind).to eq(:empty)
      expect(result.coverage[:searched]).to eq(3)
    end

    # S3a T5: the chip's narrowing is NAMED, not counted, and that must survive
    # the switch away from coverage(area:).
    it 'still names a project the thread chip narrowed to' do
      notes_only_projects
      ticket_event
      narrowed = Lalabase::Tools::Scope.new(organisation: organisation, actor: user,
                                            only_project_id: project.id)
      chipped = Lalabase::Tools::Context.new(project: nil, actor: user,
                                             organisation: organisation, scope: narrowed)

      expect(described_class.execute(args: {}, context: chipped).coverage[:chosen]).to eq(project.name)
    end
  end
end
