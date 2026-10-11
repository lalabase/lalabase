# frozen_string_literal: true

require 'rails_helper'

# What: Notifications::InboxQuery, the one owner of "which rows are this user's
#       inbox as seen through a Personal Access Token".
# Type: Service spec.
# Why:  Two surfaces answer from it (GET /api/v1/notifications, the MCP tool
#       list_notifications), so the rights rules live here and are pinned here:
#       recipient only, in_app only, not archived, organisation in reach, project
#       linked or absent. Plus the argument contract: status/since/project_id are
#       refused when unusable (a malformed uuid would otherwise cast to NULL and
#       select the project-less rows), and the paging clamps sit on their bounds.
RSpec.describe Notifications::InboxQuery do
  let(:user) { create(:user) }
  let(:stranger) { create(:user) }
  let(:org_a) { create(:organisation) }
  let(:org_b) { create(:organisation) }
  let(:org_c) { create(:organisation) }
  let(:a1) { ActsAsTenant.with_tenant(org_a) { create(:project, organisation: org_a) } }
  let(:b1) { ActsAsTenant.with_tenant(org_b) { create(:project, organisation: org_b) } }
  let(:b2) { ActsAsTenant.with_tenant(org_b) { create(:project, organisation: org_b) } }
  # org_a: every project; org_b: only b1; org_c: outside the token.
  let(:token) do
    create(:personal_access_token, user: user, organisations: [org_a, org_b], project_scopes: { org_b => [b1] })
  end
  let(:reach) { token.reach }

  # A token belongs to a person and cannot reach further than that person does. The fixtures
  # used to give the owner a token and nothing else, a shape no real account has, so every
  # example below measured the token's reach against a non-member. These grants are the
  # realistic precondition; the reach assertions are unchanged and still do their narrowing.
  before do
    ActsAsTenant.with_tenant(org_a) do
      create(:membership, user: user, organisation: org_a, active: true)
      create(:project_permission, user: user, project: a1, tickets_access: 'read_write')
    end
    ActsAsTenant.with_tenant(org_b) do
      create(:membership, user: user, organisation: org_b, active: true)
      create(:project_permission, user: user, project: b1, tickets_access: 'read_write')
      create(:project_permission, user: user, project: b2, tickets_access: 'read_write')
    end
  end

  def row(org, **attrs)
    ActsAsTenant.with_tenant(org) do
      create(:notification, { recipient: user, organisation: org, state: 'queued' }.merge(attrs))
    end
  end

  def ids(**args)
    described_class.call(user: user, reach: reach, **args).rows.map(&:id)
  end

  describe 'reach and ownership' do
    let!(:a_unread)   { row(org_a, project: a1, created_at: 5.minutes.ago) }
    let!(:a_read)     { row(org_a, project: a1, state: 'read', read_at: 1.minute.ago, created_at: 4.minutes.ago) }
    let!(:a_archived) { row(org_a, project: a1, state: 'archived', created_at: 3.minutes.ago) }
    let!(:a_email)    { row(org_a, project: a1, channel: 'email', created_at: 2.minutes.ago) }
    let!(:b_linked)   { row(org_b, project: b1, created_at: 6.minutes.ago) }
    let!(:b_unlinked) { row(org_b, project: b2, created_at: 7.minutes.ago) }
    let!(:b_system)   { row(org_b, project: nil, created_at: 8.minutes.ago) }
    let!(:c_outside)  { row(org_c, created_at: 1.minute.ago) }
    let!(:not_mine)   { row(org_a, recipient: stranger, project: a1, created_at: 1.minute.ago) }

    it 'defaults to the unread in_app rows within reach, newest first' do
      expect(ids).to eq([a_unread.id, b_linked.id, b_system.id])
    end

    it 'never lists another user, another channel, an archived row or an organisation outside the token' do
      expect(ids(status: 'all')).not_to include(not_mine.id, a_email.id, a_archived.id, c_outside.id)
    end

    it 'keeps a restricted organisation to its linked projects plus the project-less rows' do
      expect(ids(status: 'all')).to include(b_linked.id, b_system.id)
      expect(ids(status: 'all')).not_to include(b_unlinked.id)
    end

    it 'widens to read or all on request, case-insensitively' do
      expect(ids(status: 'read')).to eq([a_read.id])
      expect(ids(status: 'ALL')).to eq([a_read.id, a_unread.id, b_linked.id, b_system.id])
    end

    it 'narrows to one project with project_id, unread_total following the narrowing' do
      page = described_class.call(user: user, reach: reach, project_id: a1.id, status: 'all')
      expect(page.rows.map(&:id)).to eq([a_read.id, a_unread.id])
      expect(page.unread_total).to eq(1)
    end

    it 'counts unread_total over the reach, ignoring status and since' do
      page = described_class.call(user: user, reach: reach, status: 'read', since: 1.hour.from_now.iso8601)
      expect(page.rows).to be_empty
      expect(page.unread_total).to eq(3)
    end

    # by_organisation: the unread count per organisation in reach, for an overview of every
    # inbox at once (the terminal inbox). Same slice as unread_total, split by organisation.
    describe 'by_organisation' do
      def counts(**args)
        described_class.call(user: user, reach: reach, **args).by_organisation
      end

      it 'counts the unread rows per organisation in reach, organisations by name ignoring case' do
        # Names against the order of creation and against a case-sensitive sort ("Zeta" < "alpha").
        org_a.update!(name: 'Zeta GmbH')
        org_b.update!(name: 'alpha GmbH')
        expect(counts.map { |o| o[:id] }).to eq([org_b.id, org_a.id])
        expect(counts.to_h { |o| [o[:id], o[:unread]] }).to eq(org_a.id => 1, org_b.id => 2)
        expect(counts.to_h { |o| [o[:id], o[:name]] }).to eq(org_a.id => org_a.name, org_b.id => org_b.name)
      end

      it 'adds up to unread_total and ignores status and since, like unread_total' do
        page = described_class.call(user: user, reach: reach, status: 'read', since: 1.hour.from_now.iso8601)
        expect(page.by_organisation.sum { |o| o[:unread] }).to eq(page.unread_total)
        expect(page.by_organisation.sum { |o| o[:unread] }).to eq(3)
      end

      it 'keeps an organisation in reach with nothing unread, at 0' do
        a_unread.update_columns(state: 'read', read_at: Time.current)
        expect(counts.to_h { |o| [o[:id], o[:unread]] }).to eq(org_a.id => 0, org_b.id => 2)
      end

      it 'narrows to the organisation of project_id' do
        expect(counts(project_id: a1.id)).to eq([{ id: org_a.id, name: org_a.name, unread: 1 }])
      end

      # The reach is built first, as in a request where the membership ends meanwhile: the
      # reach alone would drop org_b too and leave the query's own check untested.
      it 'drops an organisation the person is no longer an active member of' do
        reach
        Membership.where(user: user, organisation: org_b).update_all(active: false)
        expect(counts.map { |o| o[:id] }).to eq([org_a.id])
      end
    end

    it 'answers nothing for a token with no organisation in reach' do
      empty = PersonalAccessToken::Reach.new(project_ids_by_organisation: {})
      expect(described_class.call(user: user, reach: empty, status: 'all').rows).to be_empty
    end

    it 'includes archived rows only on request (member lookups)' do
      found = ActsAsTenant.without_tenant do
        described_class.relation(user: user, reach: reach, status: 'all', include_archived: true).pluck(:id)
      end
      expect(found).to include(a_archived.id)
      expect(ids(status: 'all')).not_to include(a_archived.id)
    end

    it 'preloads what the serializer reads, so a page renders without another query' do
      page = described_class.call(user: user, reach: reach, status: 'all')
      queries = 0
      counter = ->(_name, _start, _finish, _id, payload) { queries += 1 unless payload[:name] == 'SCHEMA' }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        page.rows.each { |notification| Notifications::Serializer.row(notification) }
      end
      expect(queries).to eq(0)
    end

    # Document#title reads current_version, a belongs_to the polymorphic preload
    # does not reach. Two rows: with one, a per-row query is invisible.
    it 'preloads the document versions too, so a page of document rows renders without a per-row query' do
      # The fixtures, not the query under test, repeat identical lookups
      # (DocumentVersion#broadcast_updated per version); the counter below is
      # the assertion and runs outside the pause.
      Prosopite.pause do
        ActsAsTenant.with_tenant(org_a) do
          # A document notification is the documents area's (Notification::AREA_BY_NOTIFIABLE_TYPE).
          ProjectPermission.find_by!(user: user, project: a1).update!(documents_access: 'read_only')
          2.times do |i|
            document = create(:document, project: a1, organisation: org_a, creator: user)
            version = create(:document_version, document: document, organisation: org_a, title: "Angebot v#{i}")
            document.update!(current_version: version)
            create(:notification, recipient: user, organisation: org_a, project: a1, notifiable: document,
                                  event_type: Notifications::Constants::EVENT_TYPE_DOCUMENT_ADDED, state: 'queued')
          end
        end
      end
      page = described_class.call(user: user, reach: reach, status: 'all')
      queries = 0
      counter = ->(_name, _start, _finish, _id, payload) { queries += 1 unless payload[:name] == 'SCHEMA' }
      rows = ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        Notifications::Serializer.rows(page.rows, viewer: user)
      end
      expect(rows.count { |row| row[:notifiable][:type] == 'Document' }).to eq(2)
      expect(rows.filter_map { |row| row[:notifiable][:title] }).to include('Angebot v0', 'Angebot v1')
      expect(queries).to eq(0)
    end

    # The reach check of project_id lives in the query (both surfaces): a
    # project the token cannot see and a missing one raise the same error with
    # the same wording, so neither surface can confirm a project exists.
    it 'refuses a project_id outside the reach exactly like a missing one' do
      expect { described_class.call(user: user, reach: reach, project_id: b2.id) }
        .to raise_error(described_class::ProjectNotReachable, described_class::PROJECT_NOT_REACHABLE)
      expect { described_class.call(user: user, reach: reach, project_id: SecureRandom.uuid) }
        .to raise_error(described_class::ProjectNotReachable, described_class::PROJECT_NOT_REACHABLE)
      expect(described_class.call(user: user, reach: reach, project_id: b1.id, status: 'all').rows.map(&:id))
        .to eq([b_linked.id])
    end
  end

  # organisation_id narrows to one organisation: its rows, project-less ones
  # included, and every number of the page with them (terminal client plan, S1 a):
  # one organisation's inbox must not read empty behind the rows of another.
  describe 'organisation_id' do
    let!(:a_unread) { row(org_a, project: a1, created_at: 5.minutes.ago) }
    let!(:b_linked) { row(org_b, project: b1, created_at: 6.minutes.ago) }
    let!(:b_system) { row(org_b, project: nil, created_at: 8.minutes.ago) }
    let!(:b_read)   { row(org_b, project: b1, state: 'read', read_at: 1.minute.ago, created_at: 9.minutes.ago) }

    it 'lists that organisation only, project-less rows included, and counts the same rows' do
      page = described_class.call(user: user, reach: reach, organisation_id: org_b.id, status: 'all')
      expect(page.rows.map(&:id)).to eq([b_linked.id, b_system.id, b_read.id])
      expect(page.total).to eq(3)
      expect(page.unread_total).to eq(2)
      expect(page.by_organisation).to eq([{ id: org_b.id, name: org_b.name, unread: 2 }])
    end

    it 'keeps the token reach inside the organisation' do
      unlinked = row(org_b, project: b2, created_at: 2.minutes.ago)
      expect(ids(organisation_id: org_b.id, status: 'all')).not_to include(unlinked.id)
    end

    it 'combines with a project_id of the same organisation' do
      expect(ids(organisation_id: org_b.id, project_id: b1.id, status: 'all')).to eq([b_linked.id, b_read.id])
    end

    # The same refusal, the same words, for an organisation that does not exist,
    # one outside the token, one the person left, and a project of another
    # organisation: none of them confirms that something exists.
    it 'refuses what it cannot reach exactly like what does not exist' do
      expect { described_class.call(user: user, reach: reach, organisation_id: SecureRandom.uuid) }
        .to raise_error(described_class::OrganisationNotReachable, described_class::ORGANISATION_NOT_REACHABLE)
      expect { described_class.call(user: user, reach: reach, organisation_id: org_c.id) }
        .to raise_error(described_class::OrganisationNotReachable, described_class::ORGANISATION_NOT_REACHABLE)
      expect { described_class.call(user: user, reach: reach, organisation_id: org_a.id, project_id: b1.id) }
        .to raise_error(described_class::ProjectNotReachable, described_class::PROJECT_NOT_REACHABLE)
    end

    # The reach is built first, as in a request where the membership ends meanwhile.
    it 'refuses an organisation the person left, although the token still names it' do
      reach
      Membership.where(user: user, organisation: org_b).update_all(active: false)
      expect { described_class.call(user: user, reach: reach, organisation_id: org_b.id) }
        .to raise_error(described_class::OrganisationNotReachable, described_class::ORGANISATION_NOT_REACHABLE)
    end

    it 'refuses a malformed id before it reaches the database' do
      expect { described_class.call(user: user, reach: reach, organisation_id: 'abc') }
        .to raise_error(described_class::InvalidArgument, /organisation_id/)
    end

    # Every spelling Lalabase::Uuid.valid? lets in names the same organisation.
    it 'takes an id in capitals or without dashes like the canonical one' do
      expected = [b_linked.id, b_system.id, b_read.id]
      expect(ids(organisation_id: org_b.id.upcase, status: 'all')).to eq(expected)
      expect(ids(organisation_id: org_b.id.delete('-'), status: 'all')).to eq(expected)
    end

    it 'reads an empty organisation_id as no filter' do
      expect(ids(organisation_id: '', status: 'all')).to include(a_unread.id, b_linked.id)
    end

    # The filter narrows the inbox rule, it never replaces a part of it: another
    # person's row and another channel stay out, also in every number.
    it 'keeps the recipient and the channel' do
      foreign = row(org_b, recipient: stranger, project: nil, created_at: 2.minutes.ago)
      mail = row(org_b, project: nil, channel: 'email', created_at: 3.minutes.ago)
      page = described_class.call(user: user, reach: reach, organisation_id: org_b.id, status: 'all')
      expect(page.rows.map(&:id)).not_to include(foreign.id, mail.id)
      expect(page.total).to eq(3)
      expect(page.unread_total).to eq(2)
    end

    it 'combines with status and since, list and numbers' do
      read_page = described_class.call(user: user, reach: reach, organisation_id: org_b.id, status: 'read')
      expect(read_page.rows.map(&:id)).to eq([b_read.id])
      expect([read_page.total, read_page.unread_total]).to eq([1, 2])

      recent = described_class.call(user: user, reach: reach, organisation_id: org_b.id, status: 'all',
                                    since: 7.minutes.ago.iso8601)
      expect(recent.rows.map(&:id)).to eq([b_linked.id])
      expect([recent.total, recent.unread_total]).to eq([1, 2])
      expect(recent.by_organisation).to eq([{ id: org_b.id, name: org_b.name, unread: 2 }])
    end

    it 'keeps the chosen organisation in by_organisation at 0 when nothing is unread' do
      [b_linked, b_system].each { |n| n.update_columns(state: 'read', read_at: Time.current) }
      page = described_class.call(user: user, reach: reach, organisation_id: org_b.id, status: 'all')
      expect(page.by_organisation).to eq([{ id: org_b.id, name: org_b.name, unread: 0 }])
    end

    # An active member without a single project right still reads the
    # organisation's project-less rows: the filter must not refuse them.
    it 'serves an active member without project rights the project-less rows' do
      ActsAsTenant.with_tenant(org_b) { ProjectPermission.where(user: user).destroy_all }
      expect(ids(organisation_id: org_b.id, status: 'all')).to eq([b_system.id])
    end
  end

  # The cursor cuts on last_event_at, so the rows are ordered by it: a client
  # that advances `since` to the first row of a page cannot skip a row further
  # down whose activity is newer, and a regrouped old row surfaces at the top.
  describe 'ordering by activity' do
    it 'lists a regrouped old row before a younger row with older activity' do
      fresh = row(org_a, created_at: 1.hour.ago, last_event_at: 1.hour.ago)
      regrouped = row(org_a, created_at: 3.days.ago, last_event_at: 1.minute.ago, group_count: 2)
      expect(ids).to eq([regrouped.id, fresh.id])
    end
  end

  describe 'unread states' do
    # Production rows sit in sent/delivered after dispatch; only the fixtures are
    # queued. A narrowing to queued would empty the real inbox without a red test.
    it 'lists every unread state by default (queued, sent, delivered) and counts them, never the read row' do
      queued = row(org_a, state: 'queued', created_at: 3.minutes.ago)
      sent = row(org_a, state: 'sent', created_at: 2.minutes.ago)
      delivered = row(org_a, state: 'delivered', created_at: 1.minute.ago)
      row(org_a, state: 'read', read_at: 1.minute.ago)

      page = described_class.call(user: user, reach: reach)
      expect(page.rows.map(&:id)).to eq([delivered.id, sent.id, queued.id])
      expect(page.unread_total).to eq(3)
    end
  end

  describe 'since (rows with activity after the bound; the bound itself is excluded)' do
    let(:bound) { Time.zone.parse('2026-08-20 10:00:00') }
    let!(:before) { row(org_a, created_at: bound - 1.second, last_event_at: bound - 1.second) }
    let!(:at)     { row(org_a, created_at: bound, last_event_at: bound) }
    let!(:after)  { row(org_a, created_at: bound + 1.second, last_event_at: bound + 1.second) }

    it 'returns n+1 and neither n nor n-1' do
      expect(ids(since: bound.iso8601)).to eq([after.id])
    end

    # A grouped row keeps its created_at and moves last_event_at (the second
    # comment on the same ticket within the grouping window). A cursor on
    # created_at would hide it from a polling client.
    it 'returns a row created before the bound whose latest event came after it, ordered by that event' do
      grouped = row(org_a, created_at: bound - 1.day, last_event_at: bound + 2.seconds, group_count: 2)
      expect(ids(since: bound.iso8601)).to eq([grouped.id, after.id])
    end

    it 'takes a date-only bound as midnight and an offset bound as the same instant' do
      expect(ids(since: '2026-08-20')).to eq([after.id, at.id, before.id])
      berlin = (bound - 1.second).in_time_zone('Europe/Berlin').iso8601
      expect(berlin).to end_with('+02:00')
      expect(ids(since: berlin)).to eq([after.id, at.id])
    end

    it 'refuses a bound it cannot store or read (five-digit year, thirteenth month, prose, a space)' do
      ['99999-01-01', '2026-13-01', 'gestern', '2026-08-20 10:00'].each do |bad|
        expect { described_class.call(user: user, reach: reach, since: bad) }
          .to raise_error(described_class::InvalidArgument, /since/), bad
      end
    end
  end

  describe 'paging' do
    before { 3.times { |i| row(org_a, created_at: i.minutes.ago) } }

    # Each example runs the query several times on purpose (the bounds of one
    # rule side by side). The repeated identical SQL Prosopite sees is that
    # repetition, one preload per call, not a per-record N+1. Paused in a group
    # `before`, which runs AFTER the config-level Prosopite.scan; an `around`
    # would be undone by that scan.
    before { Prosopite.pause }

    it 'clamps per_page at the maximum: 99 stays, 100 stays, 101 becomes 100' do
      expect(described_class.call(user: user, reach: reach, per_page: 99).per_page).to eq(99)
      expect(described_class.call(user: user, reach: reach, per_page: 100).per_page).to eq(100)
      expect(described_class.call(user: user, reach: reach, per_page: 101).per_page).to eq(100)
    end

    it 'falls back to the default for a missing, zero or negative per_page and a page below 1' do
      page = described_class.call(user: user, reach: reach, per_page: 0, page: -3)
      expect(page.per_page).to eq(described_class::DEFAULT_PER_PAGE)
      expect(page.page).to eq(1)
    end

    it 'takes page and per_page as integers or numeric strings alike' do
      page = described_class.call(user: user, reach: reach, per_page: '2', page: ' 2 ')
      expect(page.per_page).to eq(2)
      expect(page.page).to eq(2)
      expect(page.rows.size).to eq(1)
    end

    # `.to_i` on an Array or a nested hash (what `?page[]=1` arrives as) used to
    # raise NoMethodError into a 500; prose used to become the default silently.
    it 'refuses a page or per_page that is not a whole number, whatever shape it arrives in' do
      [['abc', :per_page], [['1'], :page], [{ 'a' => '1' }, :per_page], ['1.5', :page]].each do |bad, name|
        expect { described_class.call(user: user, reach: reach, name => bad) }
          .to raise_error(described_class::InvalidArgument, /#{name}/), "#{name}=#{bad.inspect}"
      end
    end

    it 'refuses a page beyond MAX_PAGE (n-1/n/n+1), where the offset would overflow' do
      expect(described_class.call(user: user, reach: reach, page: described_class::MAX_PAGE - 1).rows).to be_empty
      expect(described_class.call(user: user, reach: reach, page: described_class::MAX_PAGE).rows).to be_empty
      expect { described_class.call(user: user, reach: reach, page: described_class::MAX_PAGE + 1) }
        .to raise_error(described_class::InvalidArgument, /page/)
      expect { described_class.call(user: user, reach: reach, page: 10**19) }
        .to raise_error(described_class::InvalidArgument, /page/)
    end

    it 'pages through the rows with an exact total' do
      first = described_class.call(user: user, reach: reach, per_page: 2, page: 1)
      second = described_class.call(user: user, reach: reach, per_page: 2, page: 2)
      expect(first.rows.size).to eq(2)
      expect(second.rows.size).to eq(1)
      expect(first.total).to eq(3)
      expect(described_class.call(user: user, reach: reach, per_page: 2, page: 3).rows).to be_empty
    end
  end

  describe 'argument contract' do
    it 'refuses an unknown status' do
      expect { described_class.call(user: user, reach: reach, status: 'unseen') }
        .to raise_error(described_class::InvalidArgument, /status/)
    end

    it 'refuses a malformed project_id instead of letting it cast to NULL (the project-less rows)' do
      expect { described_class.call(user: user, reach: reach, project_id: 'abc') }
        .to raise_error(described_class::InvalidArgument, /project_id/)
    end
  end

  # The token's reach is written once when the token is made and never asked again. Project
  # access changes the day someone is taken off a project. A notification needs BOTH, or the
  # API becomes the one door around the gate that every other surface applies.
  describe 'current access, on top of the reach' do
    let!(:a_row) { row(org_a, project: a1) }
    let!(:b_row) { row(org_b, project: b1) }
    let!(:b_system) { row(org_b, project: nil) }

    def permission_for(project)
      ActsAsTenant.with_tenant(project.organisation) do
        ProjectPermission.find_by(user_id: user.id, project_id: project.id)
      end
    end

    it 'lists the rows while the access is there' do
      expect(ids).to include(a_row.id, b_row.id)
    end

    it 'drops a project the person was taken off, although the token still names it' do
      permission_for(b1).update!(tickets_access: 'no_access')

      expect(ids).not_to include(b_row.id)
    end

    it 'drops it for an all_projects organisation too, where no project filter applies' do
      permission_for(a1).update!(tickets_access: 'no_access')

      expect(ids).not_to include(a_row.id)
    end

    it 'keeps the rows of the projects that are left' do
      permission_for(b1).update!(tickets_access: 'no_access')

      expect(ids).to include(a_row.id)
    end

    it 'lists them again once the access is back, with nothing restored' do
      permission_for(b1).update!(tickets_access: 'no_access')
      expect(ids).not_to include(b_row.id)

      permission_for(b1).update!(tickets_access: 'read_write')
      # A later request: project access is resolved once per request (Current memo,
      # Notification.source_projects_for), and Rails resets it between requests.
      Current.reset

      expect(ids).to include(b_row.id)
    end

    # Leaving the organisation takes its project-less system messages too. The inbox cannot
    # reach this case (it only ever renders an organisation the user is inside of), but a
    # token still names it.
    it 'drops a whole organisation the person is no longer an active member of' do
      Membership.find_by(user_id: user.id, organisation_id: org_b.id).update!(active: false)
      user.instance_variable_set(:@active_member_cache, nil)

      expect(ids).not_to include(b_row.id, b_system.id)
    end

    it 'leaves the other organisation untouched by that' do
      Membership.find_by(user_id: user.id, organisation_id: org_b.id).update!(active: false)
      user.instance_variable_set(:@active_member_cache, nil)

      expect(ids).to include(a_row.id)
    end

    # The boundary between "member with no project access" and "not a member". Both end up
    # with an empty project set, and they must NOT answer alike: the first keeps the
    # organisation's project-less system messages, the second loses the organisation whole.
    # Covered incidentally by fixtures in serializer_spec and mark_notification_read_spec
    # before; the behaviour belongs to this file, so it is decided here.
    it 'keeps the system messages of a member who has no project access left' do
      permission_for(a1).update!(tickets_access: 'no_access')
      permission_for(b1).update!(tickets_access: 'no_access')
      permission_for(b2).update!(tickets_access: 'no_access')

      expect(ids).to include(b_system.id)
      expect(ids).not_to include(a_row.id, b_row.id)
    end

    # The write paths (mark_all_as_read, the MCP tools) go through .relation, not .call. They
    # inherit the gate, and this is what says so, so a future short-cut past #base is noticed.
    it 'narrows the relation the write paths use, archived rows included' do
      permission_for(b1).update!(tickets_access: 'no_access')

      # without_tenant is the documented contract of .relation, and the shape both write
      # paths use (mark_all_as_read, MarkNotificationRead).
      seen = ActsAsTenant.without_tenant do
        described_class.relation(user: user, reach: reach, status: 'all', include_archived: true).map(&:id)
      end

      expect(seen).not_to include(b_row.id)
      expect(seen).to include(a_row.id)
    end

    # The gate asks the AREA of the subject (Notification::AREA_BY_NOTIFIABLE_TYPE), as every
    # other inbox surface does. Until 2026-10-07 it was area-blind ("may see the project at
    # all"): a person left with another area still listed ticket notifications, with the
    # ticket's current title. Project news has no single area and still counts any of them.
    # Plan: lalabase-private doc/benachrichtigungen_bereichsrechte_plan.md.
    it 'drops a ticket notification once tickets are gone, though another area is left' do
      permission_for(b1).update!(tickets_access: 'no_access', documents_access: 'read_write')

      expect(ids).not_to include(b_row.id)
    end

    it 'keeps project news while ANY area of the project is left' do
      news = row(org_b, project: b1, notifiable: b1,
                        event_type: Notifications::Constants::EVENT_TYPE_PROJECT_ANNOUNCEMENT)
      permission_for(b1).update!(tickets_access: 'no_access', documents_access: 'read_write')

      expect(ids).to include(news.id)
    end

    it 'stops once the last area is gone' do
      permission_for(b1).update!(tickets_access: 'no_access', documents_access: 'no_access')

      expect(ids).not_to include(b_row.id)
    end

    # project_id is refused the same way whether the project is outside the token's reach or
    # inside it but no longer reachable by the person. The class header promises exactly this
    # symmetry ("no existence leak"); a 200 with an empty list would break it.
    it 'refuses a project_id it can no longer reach, exactly like one outside the reach' do
      permission_for(b1).update!(tickets_access: 'no_access', documents_access: 'no_access')

      expect { described_class.call(user: user, reach: reach, project_id: b1.id) }
        .to raise_error(described_class::ProjectNotReachable)
    end

    it 'counts unread_total over the narrowed set, not the token reach' do
      before_revoke = described_class.call(user: user, reach: reach).unread_total

      permission_for(b1).update!(tickets_access: 'no_access')
      Current.reset # a later request, see 'lists them again once the access is back'

      expect(described_class.call(user: user, reach: reach).unread_total).to eq(before_revoke - 1)
    end
  end
end
