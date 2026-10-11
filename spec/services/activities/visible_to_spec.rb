# frozen_string_literal: true

require 'rails_helper'

# The rights boundary of the activity feed (assistant plan §9a Befund 1, §13-11).
#
# What makes this worth its own object: activities have NO project_id, so every
# row's project is derived from its trackable, and the area is derived from its
# key. Both derivations are places a leak can hide, and neither is visible in the
# row itself.
RSpec.describe Activities::VisibleTo do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  # A reach that answers exactly like Lalabase::Tools::Scope does, so this object
  # is exercised through the interface its real caller uses.
  def reach_of(areas)
    instance_double(Lalabase::Tools::Scope).tap do |scope|
      allow(scope).to receive(:project_ids) { |area:| Array(areas[area]) }
    end
  end

  def ticket_activity(key:, on: project, at: 1.hour.ago)
    ticket = create(:ticket, project: on, organisation: organisation)
    create(:activity, trackable: ticket, organisation: organisation, actor: user,
                      key: key, action: key.split('.').last, created_at: at)
  end

  def project_activity(key:, on: project, at: 1.hour.ago)
    create(:activity, trackable: on, organisation: organisation, actor: user,
                      key: key, action: key.split('.').last, created_at: at)
  end

  # ⚠️ Call sites pass a BRACED hash. Ruby reads a trailing `key: value` list as
  # keyword arguments, so `visible(notes: [id])` would never reach `areas`.
  def visible(areas = {}, since: nil, limit: nil)
    described_class.call(organisation: organisation, reach: reach_of(areas), since: since, limit: limit)
  end

  describe 'the area gate' do
    # The heart of it: both rows hang on the SAME project record and share the
    # same trackable_type. Only the key tells them apart.
    it 'shows a note event to a notes reader and hides the document event beside it' do
      note = project_activity(key: 'project.note_created')
      document = project_activity(key: 'project.document_created')

      rows = visible({ notes: [project.id] })

      expect(rows).to include(note)
      expect(rows).not_to include(document)
    end

    it 'shows a ticket event only where the tickets area is readable' do
      here = ticket_activity(key: 'ticket.assigned', on: project)
      there = ticket_activity(key: 'ticket.assigned', on: other_project)

      rows = visible({ tickets: [project.id] })

      expect(rows).to include(here)
      expect(rows).not_to include(there)
    end

    it 'hides everything from a reach that contains no projects' do
      ticket_activity(key: 'ticket.created')
      project_activity(key: 'project.note_created')

      expect(visible({})).to be_empty
    end

    it 'drops a row whose key the registry does not know (fail-closed)' do
      unknown = project_activity(key: 'project.erfundenes_ereignis')

      expect(visible(ProjectPermission.access_areas.index_with { [project.id] })).not_to include(unknown)
    end

    it 'drops the families that are not project-bound at all' do
      group = create(:time_session_group, organisation: organisation)
      row = create(:activity, trackable: group, organisation: organisation, actor: user,
                              key: 'time_session_group.created', action: 'created')

      expect(visible(ProjectPermission.access_areas.index_with { [project.id] })).not_to include(row)
    end
  end

  describe 'project-level events' do
    # Decided 2026-08-26: visible to anybody who may see the project at all,
    # which is what read on ANY area amounts to.
    it 'shows a project rename to somebody who only reads notes there' do
      renamed = project_activity(key: 'project.updated')

      expect(visible({ notes: [project.id] })).to include(renamed)
    end

    it 'hides it in a project the reader reaches through no area at all' do
      renamed = project_activity(key: 'project.updated', on: other_project)

      expect(visible({ notes: [project.id] })).not_to include(renamed)
    end

    # ⚠️ The trap this guards: asking the reach for a `:project` area would raise,
    # because accessible_project_ids only knows the real permission columns
    # (§2.4, the same trap as `:time_sessions`).
    it 'never asks the reach for an area ProjectPermission does not have' do
      scope = reach_of({ notes: [project.id] })
      project_activity(key: 'project.updated')

      described_class.call(organisation: organisation, reach: scope).to_a

      # at_least(:once): an area that carries keys AND takes part in the
      # project-level union is asked twice. The real Lalabase::Tools::Scope
      # memoises per area, so that costs no second query.
      ProjectPermission.access_areas.each do |area|
        expect(scope).to have_received(:project_ids).with(area: area).at_least(:once)
      end
      expect(scope).not_to have_received(:project_ids).with(area: :project)
    end
  end

  describe 'the window and the order' do
    it 'keeps only rows inside the since window' do
      recent = ticket_activity(key: 'ticket.created', at: 2.hours.ago)
      old = ticket_activity(key: 'ticket.created', at: 8.days.ago)

      rows = visible({ tickets: [project.id] }, since: 7.days.ago)

      expect(rows).to include(recent)
      expect(rows).not_to include(old)
    end

    it 'answers newest first' do
      older = ticket_activity(key: 'ticket.created', at: 3.hours.ago)
      newer = ticket_activity(key: 'ticket.created', at: 1.hour.ago)

      expect(visible({ tickets: [project.id] }).to_a.first(2)).to eq([newer, older])
    end

    it 'honours a limit' do
      3.times { |i| ticket_activity(key: 'ticket.created', at: (i + 1).hours.ago) }

      expect(visible({ tickets: [project.id] }, limit: 2).to_a.size).to eq(2)
    end
  end

  describe 'cross-organisation isolation' do
    it 'never leaves its own organisation, even for an id that is reachable elsewhere' do
      foreign_org = create(:organisation)
      foreign_project = nil
      foreign_row = nil
      ActsAsTenant.with_tenant(foreign_org) do
        foreign_project = create(:project, organisation: foreign_org)
        foreign_ticket = create(:ticket, project: foreign_project, organisation: foreign_org)
        foreign_row = create(:activity, trackable: foreign_ticket, organisation: foreign_org,
                                        actor: user, key: 'ticket.created', action: 'created')
      end

      rows = visible({ tickets: [project.id, foreign_project.id] })

      expect(rows).not_to include(foreign_row)
    end
  end

  # The number a caller puts under its answer. It used to come from ONE area, and
  # that is how a reader with notes-only rights got an answer out of three
  # projects labelled "Durchsucht: 0 von 3 Projekten".
  describe '#reached_project_ids' do
    def feed(areas)
      described_class.new(organisation: organisation, reach: reach_of(areas))
    end

    it 'is the union over every area, not the reach of one of them' do
      reach = feed({ notes: [project.id], tickets: [other_project.id] }).reached_project_ids

      expect(reach).to match_array([project.id, other_project.id])
    end

    it 'names each project once, however many areas reach it' do
      reach = feed({ notes: [project.id], tickets: [project.id], meetings: [project.id] })

      expect(reach.reached_project_ids).to eq([project.id])
    end

    it 'is empty when no area reaches anything' do
      expect(feed({}).reached_project_ids).to eq([])
    end
  end
end
