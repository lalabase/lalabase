# frozen_string_literal: true

# == Schema Information
#
# Table name: time_sessions
#
#  id                    :uuid             not null, primary key
#  billed                :boolean          default(FALSE), not null
#  billed_at             :datetime
#  customer_description  :text
#  deleted_at            :datetime
#  description           :text
#  duration              :integer          not null
#  invoice_number        :string
#  occurred_on           :datetime         not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  creator_id            :uuid             not null
#  meeting_id            :uuid
#  organisation_id       :uuid             not null
#  project_id            :uuid             not null
#  ticket_id             :uuid
#  time_session_group_id :uuid
#
# Indexes
#
#  index_time_sessions_active_project_occurred        (deleted_at,project_id,occurred_on)
#  index_time_sessions_on_billed                      (billed)
#  index_time_sessions_on_creator_id                  (creator_id)
#  index_time_sessions_on_creator_id_and_occurred_on  (creator_id,occurred_on)
#  index_time_sessions_on_customer_description        (customer_description) WHERE (customer_description IS NOT NULL)
#  index_time_sessions_on_deleted_at                  (deleted_at)
#  index_time_sessions_on_meeting_id                  (meeting_id)
#  index_time_sessions_on_organisation_id             (organisation_id)
#  index_time_sessions_on_project_billed              (project_id,billed_at)
#  index_time_sessions_on_project_id                  (project_id)
#  index_time_sessions_on_project_occurred            (project_id,occurred_on)
#  index_time_sessions_on_ticket_id                   (ticket_id)
#  index_time_sessions_on_ticket_occurred             (ticket_id,occurred_on)
#  index_time_sessions_on_time_session_group_id       (time_session_group_id)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (meeting_id => meetings.id) ON DELETE => nullify
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (ticket_id => tickets.id)
#  fk_rails_...  (time_session_group_id => time_session_groups.id)
#
require 'rails_helper'

# Mutation-hardened spec for TimeSession (previously untested).
# Covers the decision points: required fields + DB NOT NULL, numericality > 0
# (boundary 0!), billed default, soft-delete default_scope, duration_string parsing
# (all branches), billed edit guard, formatting helpers, scopes, tenant isolation.
RSpec.describe TimeSession, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:creator)      { create(:user, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # Valid baseline with a PERSISTED creator: the model validates creator_id/project_id
  # as an ID (presence), and a merely built association record has no ID yet.
  # This way negative tests break on the targeted field instead of incidentally on creator_id.
  def build_session(**attrs)
    build(:time_session, { project: project, organisation: organisation, creator: creator }.merge(attrs))
  end

  describe 'associations' do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:creator).class_name('User') }
    it { is_expected.to belong_to(:ticket).optional }
    it { is_expected.to belong_to(:meeting).optional }
    it { is_expected.to belong_to(:time_session_group).optional }
  end

  # Gespräche Slice 2: a session's subject is a Ticket OR a Meeting, never both.
  # Enforced at two layers — the #at_most_one_subject validation (clean form error)
  # and the DB check constraint time_sessions_single_subject (defense in depth).
  describe 'Subjekt (Ticket XOR Meeting)' do
    let(:ticket)  { create(:ticket, project: project, creator: creator) }
    let(:meeting) { create(:meeting, project: project, organisation: organisation, creator: creator) }

    it 'ist valide mit nur ticket_id' do
      expect(build_session(ticket: ticket, meeting: nil)).to be_valid
    end

    it 'ist valide mit nur meeting_id' do
      expect(build_session(ticket: nil, meeting: meeting)).to be_valid
    end

    it 'ist valide ganz ohne Betreff (weder Ticket noch Meeting = reiner Zeit-Anker)' do
      # Guards the boundary: a subject is OPTIONAL. A mutation that turns
      # #at_most_one_subject into a "requires exactly one subject" rule dies here.
      expect(build_session(ticket: nil, meeting: nil)).to be_valid
    end

    it 'ist ungueltig mit ticket_id UND meeting_id und meldet single_subject sauber' do
      # Two assertions on purpose: not_to be_valid dies if the validation is
      # removed; the specific message dies if #at_most_one_subject flips its
      # `&&` to `||` (a bare `errors[:base] present` would survive that, because
      # an only-ticket session would then also raise a base error).
      ts = build_session(ticket: ticket, meeting: meeting)
      expect(ts).not_to be_valid
      expect(ts.errors[:base])
        .to include(I18n.t('activerecord.errors.models.time_session.single_subject'))
    end

    it 'wirft den DB-Check-Constraint bei beiden Betreffen trotz umgangener Validierung' do
      ts = build_session(ticket: ticket, meeting: meeting)
      expect { ts.save!(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid, /time_sessions_single_subject/)
    end

    it 'beruehrt das Meeting beim Speichern einer Session (touch: true)' do
      # touch: keeps the subject's updated_at fresh (cache/recency contract).
      # update_column gives a deterministic "old" timestamp so the assertion is
      # not clock-resolution dependent; removing `touch: true` leaves it stale.
      m = create(:meeting, project: project, organisation: organisation, creator: creator)
      m.update_column(:updated_at, 1.day.ago)
      stale = m.updated_at

      create(:time_session, project: project, organisation: organisation, creator: creator, meeting: m)

      expect(m.reload.updated_at).to be > stale
    end
  end

  describe '#subject' do
    let(:ticket)  { create(:ticket, project: project, creator: creator) }
    let(:meeting) { create(:meeting, project: project, organisation: organisation, creator: creator) }

    it 'is the ticket when the session hangs off a ticket' do
      expect(build_session(ticket: ticket).subject).to eq(ticket)
    end

    it 'is the meeting when the session hangs off a meeting' do
      expect(build_session(meeting: meeting).subject).to eq(meeting)
    end

    it 'is nil for a session that only has its project' do
      # The boundary that matters: "no subject" must stay distinguishable from
      # "meeting subject" — collapsing the two is the bug this whole seam fixes.
      expect(build_session(ticket: nil, meeting: nil).subject).to be_nil
    end
  end

  # Regression (Bezug-Umbau 2026-07-31): the billing views grouped by .ticket
  # alone. Every meeting-booked session of a billing period therefore fell into the
  # same nil bucket and rendered as ONE anonymous "Ohne Ticket" row with the
  # durations summed — an invoice line a customer cannot account for.
  describe '.group_by_subject' do
    let(:ticket)   { create(:ticket, project: project, creator: creator, title: 'Alpha') }
    let(:meeting)  { create(:meeting, project: project, organisation: organisation, creator: creator, title: 'Kickoff') }
    let(:meeting2) { create(:meeting, project: project, organisation: organisation, creator: creator, title: 'Retro') }

    def session_for(**attrs)
      create(:time_session, { project: project, organisation: organisation, creator: creator }.merge(attrs))
    end

    it 'keeps two different meetings in two separate groups' do
      # THE regression. Grouping by .ticket returns {nil => [both]} here, so this
      # example fails on the old implementation and on any mutation that maps a
      # meeting back onto nil.
      a = session_for(meeting: meeting)
      b = session_for(meeting: meeting2)

      grouped = described_class.group_by_subject([a, b])

      expect(grouped.keys).to contain_exactly(meeting, meeting2)
      expect(grouped[meeting]).to eq([a])
      expect(grouped[meeting2]).to eq([b])
    end

    it 'never merges meeting-booked time into the no-subject group' do
      with_meeting = session_for(meeting: meeting)
      without      = session_for(ticket: nil, meeting: nil)

      grouped = described_class.group_by_subject([with_meeting, without])

      expect(grouped[meeting]).to eq([with_meeting])
      expect(grouped[nil]).to eq([without])
    end

    it 'trails the no-subject group even behind a subject whose title sorts last' do
      # The predecessor sorted the nil group under the literal 'zzz_no_subject',
      # which a real title beginning with "zzz" would have overtaken. The rank
      # tuple makes that structural rather than lexical.
      late = create(:meeting, project: project, organisation: organisation, creator: creator, title: 'zzzz last')
      none = session_for(ticket: nil, meeting: nil)
      with = session_for(meeting: late)

      expect(described_class.group_by_subject([none, with]).keys).to eq([late, nil])
    end

    context 'with order: :ticket_number' do
      it 'orders tickets ascending by number, not alphabetically by title' do
        # 10 vs 9 also kills a mutation that sorts the number as a string.
        low  = create(:ticket, project: project, creator: creator, title: 'Zulu')
        high = create(:ticket, project: project, creator: creator, title: 'Alpha')
        low.update_column(:number, 9)
        high.update_column(:number, 10)
        sessions = [session_for(ticket: high), session_for(ticket: low)]

        grouped = described_class.group_by_subject(sessions, order: :ticket_number)

        expect(grouped.keys).to eq([low, high])
      end

      it 'breaks a tie between two projects sharing a ticket number, deterministically' do
        # Ticket numbers are unique per project, so one billing can bundle two #5.
        # Without the title tiebreaker their order is undefined and the same
        # invoice annex renders differently on a reload.
        other_project = create(:project, organisation: organisation)
        zulu  = create(:ticket, project: project, creator: creator, title: 'Zulu')
        alpha = create(:ticket, project: other_project, creator: creator, title: 'Alpha')
        zulu.update_column(:number, 5)
        alpha.update_column(:number, 5)
        sessions = [session_for(ticket: zulu), create(:time_session, project: other_project, organisation: organisation,
                                                                     creator: creator, ticket: alpha)]

        keys = described_class.group_by_subject(sessions, order: :ticket_number).keys

        expect(keys).to eq([alpha, zulu])
      end

      it 'places meetings after every ticket, and the no-subject group last' do
        sessions = [session_for(ticket: nil, meeting: nil), session_for(meeting: meeting), session_for(ticket: ticket)]

        grouped = described_class.group_by_subject(sessions, order: :ticket_number)

        expect(grouped.keys).to eq([ticket, meeting, nil])
      end
    end

    context 'with order: :title (the time list)' do
      it 'sorts type-blind: a meeting can precede a ticket' do
        # The time list has always been one alphabetical run. Locking it here so
        # the billing order (:ticket_number) cannot silently become the default.
        early = create(:meeting, project: project, organisation: organisation, creator: creator, title: 'Aaa retro')
        sessions = [session_for(ticket: ticket), session_for(meeting: early)]

        grouped = described_class.group_by_subject(sessions, order: :title)

        expect(grouped.keys).to eq([early, ticket])
      end

      it 'is the default order' do
        expect(described_class.group_by_subject([]).keys).to eq(described_class.group_by_subject([], order: :title).keys)
      end
    end

    it 'rejects an unknown order instead of silently falling back' do
      expect { described_class.group_by_subject([], order: :by_whatever) }
        .to raise_error(ArgumentError, /unknown subject order/)
    end
  end

  # Plan decision 7: a billed/grouped session must NEVER be dragged along by a
  # meeting deletion — dependent: :nullify (app) mirrored by on_delete: :nullify (DB).
  # Both layers are exercised SEPARATELY: destroy exercises the app callback,
  # delete (no callbacks) exercises the DB FK — otherwise the DB FK masks the
  # removal of the app-level dependent: :nullify and vice versa.
  describe 'Meeting-Loeschung (dependent: :nullify, App + DB)' do
    it 'behaelt eine berechnete Session bei meeting.destroy und nullt nur meeting_id (App-Ebene)' do
      meeting = create(:meeting, project: project, organisation: organisation, creator: creator)
      session = create(:time_session, project: project, organisation: organisation, creator: creator, meeting: meeting)
      session.update!(billed: true)

      meeting.destroy!

      expect(TimeSession.find(session.id).meeting_id).to be_nil
      expect(TimeSession.find(session.id).billed).to be(true)
    end

    it 'nullt meeting_id auch bei meeting.delete unter Umgehung der App-Callbacks (DB-FK-Ebene)' do
      # meeting.delete skips dependent: :nullify entirely — this proves the DB
      # foreign key on_delete: :nullify holds on its own (defense in depth). If
      # someone drops the FK or sets it to RESTRICT, this row would either keep a
      # dangling meeting_id or the delete would raise — both fail here.
      meeting = create(:meeting, project: project, organisation: organisation, creator: creator)
      session = create(:time_session, project: project, organisation: organisation, creator: creator, meeting: meeting)

      meeting.delete

      expect(TimeSession.find(session.id).meeting_id).to be_nil
    end
  end

  describe 'Pflichtfelder + Numericality' do
    it 'ist mit gueltigen Attributen valide' do
      expect(build_session).to be_valid
    end

    %i[occurred_on duration project_id creator_id].each do |attr|
      it "ist ungueltig ohne #{attr}" do
        ts = build_session
        ts.public_send("#{attr}=", nil)
        expect(ts).not_to be_valid
        expect(ts.errors[attr]).to be_present
      end
    end

    describe 'duration numericality > 0 (Boundary)' do
      it 'lehnt duration = 0 ab (Grenze, killt >= statt >)' do
        ts = build_session(duration: 0)
        expect(ts).not_to be_valid
        expect(ts.errors[:duration]).to be_present
      end

      it 'akzeptiert duration = 1 (knapp ueber der Grenze)' do
        expect(build_session(duration: 1)).to be_valid
      end

      it 'lehnt negative duration ab' do
        expect(build_session(duration: -5)).not_to be_valid
      end
    end

    # One day is the ceiling for a single booking (MAX_DURATION_MINUTES); the
    # bound holds on every surface, so a runaway figure never reaches the
    # integer column's own limit. n-1/n/n+1 around the ceiling.
    describe 'duration <= MAX_DURATION_MINUTES (Boundary)' do
      it 'akzeptiert 1439 und 1440 Minuten, lehnt 1441 ab' do
        expect(build_session(duration: described_class::MAX_DURATION_MINUTES - 1)).to be_valid
        expect(build_session(duration: described_class::MAX_DURATION_MINUTES)).to be_valid
        ts = build_session(duration: described_class::MAX_DURATION_MINUTES + 1)
        expect(ts).not_to be_valid
        expect(ts.errors[:duration]).to be_present
      end

      it 'lehnt eine Dauer im Zeitformat ab, die den Tag sprengt, statt sie zu speichern' do
        ts = build_session(duration: nil)
        ts.duration_string = '99999999999:00'
        expect(ts).not_to be_valid
        expect(ts.errors[:duration]).to be_present
      end

      # The ceiling is for NEW figures. Rows above it exist from before the rule
      # (note_spec carried duration 3600 for years, and there never was a check
      # constraint); a rule on every save would freeze them: no description edit,
      # no move in or out of a billing group.
      it 'laesst eine gespeicherte Zeile ueber der Grenze speicherbar, solange ihre Dauer unberuehrt bleibt' do
        legacy = build_session(duration: described_class::MAX_DURATION_MINUTES + 1560)
        legacy.save!(validate: false)
        expect { legacy.update!(description: 'a harmless edit') }.not_to raise_error
        expect(legacy.reload.duration).to eq(described_class::MAX_DURATION_MINUTES + 1560)
      end

      it 'wendet die Grenze an, sobald die Dauer so einer Zeile geaendert wird' do
        legacy = build_session(duration: 3000)
        legacy.save!(validate: false)
        legacy.duration = 2000
        expect(legacy).not_to be_valid
        expect(legacy.errors[:duration]).to be_present
      end
    end

    describe 'duration_string parsing edges' do
      it 'liest "1:" als eine Stunde statt in before_validation abzustuerzen' do
        ts = build_session(duration: nil)
        ts.duration_string = '1:'
        expect { ts.valid? }.not_to raise_error
        expect(ts.duration).to eq(60)
      end

      it 'liest ":" und "::" ohne Absturz und lehnt sie als Format ab' do
        [':', '::'].each do |raw|
          ts = build_session(duration: nil)
          ts.duration_string = raw
          expect { ts.valid? }.not_to raise_error
          expect(ts).not_to be_valid
          expect(ts.errors[:duration_string]).to be_present
        end
      end
    end
  end

  describe 'DB-Constraints (defense in depth)' do
    it 'wirft NOT NULL bei fehlender duration trotz umgangener Validierung' do
      ts = build(:time_session, project: project, organisation: organisation, duration: nil)
      expect { ts.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it 'wirft NOT NULL bei fehlendem project trotz umgangener Validierung' do
      ts = build(:time_session, project: nil, organisation: organisation, duration: 60)
      expect { ts.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe 'billed-Default (Vertrag)' do
    it 'defaultet billed auf false (nicht via Factory gesetzt)' do
      ts = create(:time_session, project: project, organisation: organisation)
      expect(ts.reload.billed).to be(false)
    end
  end

  describe 'Soft-Delete (default_scope deleted_at IS NULL)' do
    it 'blendet soft-geloeschte Sessions aus dem Default-Scope aus' do
      ts = create(:time_session, project: project, organisation: organisation)
      # update_column sets deleted_at DELIBERATELY past validations/callbacks
      # (otherwise prevent_changes_when_billed would not be relevant, but we want
      # to test purely the soft-delete scope, not the save path).
      ts.update_column(:deleted_at, Time.current)

      expect(TimeSession.all).not_to include(ts)
      expect(TimeSession.unscoped.where(id: ts.id)).to exist
    end
  end

  describe '#duration_string= / parse_duration_string (before_validation, alle Branches)' do
    def parsed_duration(input)
      ts = build_session(duration: nil)
      ts.duration_string = input
      ts.valid?
      ts.duration
    end

    it 'parst HH:MM ("1:30" -> 90)' do
      expect(parsed_duration('1:30')).to eq(90)
    end

    it 'parst reine Minuten ("90" -> 90)' do
      expect(parsed_duration('90')).to eq(90)
    end

    it 'parst Dezimalstunden mit Punkt ("1.5" -> 90)' do
      expect(parsed_duration('1.5')).to eq(90)
    end

    it 'parst Dezimalstunden mit Komma ("1,5" -> 90)' do
      expect(parsed_duration('1,5')).to eq(90)
    end

    it 'laesst duration unveraendert bei leerem String' do
      ts = build_session(duration: 42)
      ts.duration_string = ''
      ts.valid?
      expect(ts.duration).to eq(42)
    end
  end

  describe 'validate_duration_format' do
    it 'lehnt ein unparsbares Format ab' do
      ts = build_session
      ts.duration_string = 'abc'
      expect(ts).not_to be_valid
      expect(ts.errors[:duration_string]).to be_present
    end

    it 'akzeptiert ein gueltiges HH:MM-Format' do
      ts = build_session(duration: nil)
      ts.duration_string = '2:15'
      expect(ts).to be_valid
    end
  end

  describe 'prevent_changes_when_billed (Edit-Guard)' do
    let(:session) { create(:time_session, project: project, organisation: organisation) }

    it 'verbietet inhaltliche Aenderungen an einer abgerechneten Session' do
      session.update!(billed: true)
      session.description = 'nachtraeglich geaendert'
      expect(session).not_to be_valid
      expect(session.errors[:base]).to be_present
    end

    it 'erlaubt das Aendern NUR des billed-Flags' do
      session.update!(billed: true)
      expect(session.update(billed: false)).to be(true)
    end

    it 'erlaubt inhaltliche Aenderungen an einer NICHT abgerechneten Session' do
      expect(session.update(description: 'frei editierbar')).to be(true)
    end
  end

  describe '#editable? / #grouped?' do
    it 'editable? ist true solange nicht abgerechnet' do
      expect(build(:time_session, billed: false).editable?).to be(true)
    end

    it 'editable? ist false wenn abgerechnet' do
      expect(build(:time_session, billed: true).editable?).to be(false)
    end

    it 'grouped? spiegelt das Vorhandensein einer Gruppe' do
      expect(build(:time_session, time_session_group: nil).grouped?).to be(false)
    end
  end

  describe '#duration_string (Getter-Formatierung)' do
    it 'formatiert Minuten als HH:MM' do
      expect(build(:time_session, duration: 90).duration_string).to eq('01:30')
    end

    it 'liefert 00:00 bei nil-duration' do
      expect(build(:time_session, duration: nil).duration_string).to eq('00:00')
    end

    it 'bevorzugt einen gesetzten _duration_string-Rohwert' do
      ts = build(:time_session, duration: 90)
      ts.duration_string = '7:07'
      expect(ts.duration_string).to eq('7:07')
    end
  end

  describe '.format_duration (Klassen-Helper)' do
    it { expect(described_class.format_duration(90)).to eq('01:30') }
    it { expect(described_class.format_duration(150)).to eq('02:30') }
    it 'liefert 00:00 bei 0 und nil' do
      expect(described_class.format_duration(0)).to eq('00:00')
      expect(described_class.format_duration(nil)).to eq('00:00')
    end
  end

  describe 'Scopes' do
    it 'billed/unbilled trennen nach Abrechnungsstatus' do
      open   = create(:time_session, project: project, organisation: organisation)
      billed = create(:time_session, project: project, organisation: organisation)
      billed.update!(billed: true)

      expect(TimeSession.billed).to contain_exactly(billed)
      expect(TimeSession.unbilled).to contain_exactly(open)
    end

    it 'grouped/without_group trennen nach Gruppenzugehoerigkeit' do
      group = create(:time_session_group, organisation: organisation, creator: creator)
      in_group = create(:time_session, project: project, organisation: organisation, time_session_group: group)
      no_group = create(:time_session, project: project, organisation: organisation)

      expect(TimeSession.grouped).to contain_exactly(in_group)
      expect(TimeSession.without_group).to contain_exactly(no_group)
    end
  end

  describe 'Tenant-Isolation (acts_as_tenant)' do
    it 'sieht Sessions eines anderen Tenants nicht im Default-Scope' do
      mine = create(:time_session, project: project, organisation: organisation)

      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        create(:time_session, project: other_project, organisation: other_org)
        expect(TimeSession.all).not_to include(mine)
      end

      expect(TimeSession.all).to include(mine)
    end
  end
end
