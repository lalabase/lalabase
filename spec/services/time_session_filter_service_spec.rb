# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TimeSessionFilterService, type: :service do
  let(:organisation) { create(:organisation) }
  let(:project1) { create(:project, organisation: organisation, name: 'Project Alpha') }
  let(:project2) { create(:project, organisation: organisation, name: 'Project Beta') }
  let(:user1) { create(:user) }
  let(:user2) { create(:user) }

  let(:ticket1) { create(:ticket, project: project1, title: 'Feature Implementation') }
  let(:ticket2) { create(:ticket, project: project1, title: 'Bug Fix Database') }
  let(:ticket3) { create(:ticket, project: project2, title: 'Code Review') }

  let(:group1) { create(:time_session_group, organisation: organisation, name: 'Development') }
  let(:group2) { create(:time_session_group, organisation: organisation, name: 'Testing') }

  let(:base_query) { TimeSession.all }

  # Points in time for precise date tests
  let(:today) { Date.current }
  let(:yesterday) { 1.day.ago.to_date }
  let(:two_days_ago) { 2.days.ago.to_date }
  let(:three_days_ago) { 3.days.ago.to_date }
  let(:one_week_ago) { 1.week.ago.to_date }

  before do
    ActsAsTenant.current_tenant = organisation

    # Various test TimeSessions for extensive tests
    @ts_recent_unbilled = create(:time_session,
                                 project: project1,
                                 ticket: ticket1,
                                 creator: user1,
                                 occurred_on: yesterday,
                                 billed: false,
                                 description: 'Implementing new feature with database integration',
                                 time_session_group: group1,
                                 duration: 120) # 2 hours

    @ts_old_billed = create(:time_session,
                            project: project1,
                            ticket: ticket2,
                            creator: user2,
                            occurred_on: one_week_ago,
                            billed: true,
                            description: 'Fixed critical database performance issue',
                            time_session_group: group2,
                            duration: 90) # 1.5 hours

    @ts_without_group = create(:time_session,
                               project: project1,
                               creator: user1,
                               occurred_on: two_days_ago,
                               billed: false,
                               description: 'Code review and documentation',
                               time_session_group: nil,
                               duration: 45)

    @ts_different_project = create(:time_session,
                                   project: project2,
                                   ticket: ticket3,
                                   creator: user1,
                                   occurred_on: yesterday,
                                   billed: false,
                                   description: 'Testing new deployment pipeline',
                                   time_session_group: group1,
                                   duration: 180) # 3 hours

    @ts_no_ticket = create(:time_session,
                           project: project2,
                           creator: user2,
                           occurred_on: three_days_ago,
                           billed: true,
                           description: 'General project management tasks',
                           time_session_group: nil,
                           duration: 60) # 1 hour
  end

  describe '#call' do
    context 'ohne Filter' do
      let(:service) { described_class.new(base_query: base_query) }

      it 'gibt alle TimeSessions zurück' do
        result = service.call
        expect(result.count).to eq(5)
        expect(result.to_a).to contain_exactly(
          @ts_recent_unbilled, @ts_old_billed, @ts_without_group,
          @ts_different_project, @ts_no_ticket
        )
      end

      it 'behält die ursprüngliche Query-Klasse bei' do
        result = service.call
        expect(result).to be_a(ActiveRecord::Relation)
        expect(result.model).to eq(TimeSession)
      end
    end

    describe 'Projekt-Filter' do
      context 'mit project_id_filter' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            project_id_filter: project1.id.to_s
          )
        end

        it 'filtert nach spezifischem Projekt' do
          result = service.call
          expect(result.count).to eq(3)
          expect(result.pluck(:project_id)).to all(eq(project1.id))
          expect(result.to_a).to contain_exactly(
            @ts_recent_unbilled, @ts_old_billed, @ts_without_group
          )
        end
      end

      context 'mit gesetztem project Parameter' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            project: project1,
            project_id_filter: project2.id.to_s # should be ignored
          )
        end

        it 'ignoriert project_id_filter wenn project gesetzt ist' do
          result = service.call
          # project_id_filter is ignored, all sessions are returned
          expect(result.count).to eq(5)
        end
      end

      context 'ohne Projekt-Context' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            project: nil,
            project_id_filter: project2.id.to_s
          )
        end

        it 'wendet project_id_filter an wenn kein project gesetzt' do
          result = service.call
          expect(result.count).to eq(2)
          expect(result.pluck(:project_id)).to all(eq(project2.id))
        end
      end
    end

    describe 'Ticket-Filter' do
      let(:service) do
        described_class.new(
          base_query: base_query,
          ticket_id: ticket1.id.to_s
        )
      end

      it 'filtert nach spezifischem Ticket' do
        result = service.call
        expect(result.count).to eq(1)
        expect(result.first).to eq(@ts_recent_unbilled)
        expect(result.first.ticket).to eq(ticket1)
      end

      context 'mit nicht-existierender ticket_id' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            ticket_id: '00000000-0000-0000-0000-000000000000'
          )
        end

        it 'gibt leeres Ergebnis zurück' do
          result = service.call
          expect(result.count).to eq(0)
        end
      end

      context 'mit leerem ticket_id' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            ticket_id: ''
          )
        end

        it 'ignoriert leere ticket_id' do
          result = service.call
          expect(result.count).to eq(5)
        end
      end
    end

    describe 'Abrechnungsstatus-Filter' do
      context 'unbilled' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            billing_status: 'unbilled'
          )
        end

        it 'filtert nach nicht abgerechneten TimeSessions' do
          result = service.call
          expect(result.count).to eq(3)
          expect(result.to_a).to contain_exactly(
            @ts_recent_unbilled, @ts_without_group, @ts_different_project
          )
          expect(result.all? { |ts| !ts.billed? }).to be true
        end
      end

      context 'billed' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            billing_status: 'billed'
          )
        end

        it 'filtert nach abgerechneten TimeSessions' do
          result = service.call
          expect(result.count).to eq(2)
          expect(result.to_a).to contain_exactly(@ts_old_billed, @ts_no_ticket)
          expect(result.all?(&:billed?)).to be true
        end
      end

      context 'mit ungültigem billing_status' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            billing_status: 'invalid_status'
          )
        end

        it 'ignoriert ungültigen Status' do
          result = service.call
          expect(result.count).to eq(5)
        end
      end

      context 'mit leerem billing_status' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            billing_status: ''
          )
        end

        it 'ignoriert leeren Status' do
          result = service.call
          expect(result.count).to eq(5)
        end
      end

      # The multi-select wins over the legacy single value whenever it is there.
      context 'mit status_filters neben billing_status' do
        it 'lässt status_filters entscheiden' do
          result = described_class.new(base_query: base_query, status_filters: ['billed'], billing_status: 'unbilled').call

          expect(result.to_a).to contain_exactly(@ts_old_billed, @ts_no_ticket)
        end

        # All three states on is no narrowing, and the legacy param has no say
        # under it. Before the S4 review the service fell through to it here, so
        # an old address with billing_status showed three lit pills over a
        # filtered list.
        it 'ignoriert billing_status, sobald alle drei Zustände an sind' do
          result = described_class.new(base_query: base_query,
                                       status_filters: TimeSession::BILLING_STATUS_FILTERS,
                                       billing_status: 'unbilled').call

          expect(result.count).to eq(5)
        end

        it 'ignoriert billing_status auch bei doppelt genannten Zuständen' do
          result = described_class.new(base_query: base_query,
                                       status_filters: TimeSession::BILLING_STATUS_FILTERS + ['billed'],
                                       billing_status: 'unbilled').call

          expect(result.count).to eq(5)
        end

        # Three ELEMENTS are not three STATES: two distinct states among
        # duplicates must still narrow. A size-based check (filters.size >= 3)
        # would pass both examples above and quietly turn this address
        # unfiltered again.
        it 'filtert bei drei Elementen mit nur zwei Zuständen' do
          result = described_class.new(base_query: base_query,
                                       status_filters: %w[billed billed in_billing],
                                       billing_status: 'unbilled').call

          expect(result.to_a).to contain_exactly(@ts_old_billed, @ts_no_ticket,
                                                 @ts_recent_unbilled, @ts_different_project)
        end

        # Junk is nobody's filter: the service intersects with the constant
        # itself instead of trusting every caller to sanitize. Values it does
        # not know neither narrow nor crash, and they do not silence the
        # legacy param either.
        it 'fällt bei reinen Junk-Werten auf billing_status zurück' do
          result = described_class.new(base_query: base_query,
                                       status_filters: ['bogus'],
                                       billing_status: 'unbilled').call

          expect(result.to_a).to contain_exactly(@ts_recent_unbilled, @ts_without_group,
                                                 @ts_different_project)
        end

        it 'lässt reine Junk-Werte ohne Legacy-Param ungefiltert durch' do
          result = described_class.new(base_query: base_query, status_filters: ['bogus']).call

          expect(result.count).to eq(5)
        end
      end
    end

    describe 'Datumsbereich-Filter' do
      context 'mit vollständigem Datumsbereich' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            start_date: three_days_ago.to_s,
            end_date: yesterday.to_s
          )
        end

        it 'filtert nach Datumsbereich (inklusiv)' do
          result = service.call
          expect(result.count).to eq(4)
          # one_week_ago should be excluded
          expect(result.to_a).to contain_exactly(
            @ts_recent_unbilled, @ts_without_group, @ts_different_project, @ts_no_ticket
          )
        end
      end

      context 'nur mit Start-Datum' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            start_date: two_days_ago.to_s
          )
        end

        it 'filtert ab Start-Datum' do
          result = service.call
          expect(result.count).to eq(3)
          expect(result.to_a).to contain_exactly(
            @ts_recent_unbilled, @ts_without_group, @ts_different_project
          )
        end
      end

      context 'nur mit End-Datum' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            end_date: two_days_ago.to_s
          )
        end

        it 'filtert bis End-Datum' do
          result = service.call
          expect(result.count).to eq(3)
          expect(result.to_a).to contain_exactly(
            @ts_old_billed, @ts_without_group, @ts_no_ticket
          )
        end
      end

      context 'mit ungültigen Datumsformaten' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            start_date: 'invalid-date',
            end_date: '2023-13-45' # invalid day/month
          )
        end

        it 'ignoriert ungültige Daten und gibt alle Ergebnisse zurück' do
          result = service.call
          expect(result.count).to eq(5)
        end
      end

      context 'mit Start-Datum nach End-Datum' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            start_date: yesterday.to_s,
            end_date: three_days_ago.to_s
          )
        end

        it 'gibt leeres Ergebnis zurück' do
          result = service.call
          expect(result.count).to eq(0)
        end
      end
    end

    describe 'Creator-Filter' do
      it 'filtert nur auf Sessions des angegebenen Creators' do
        result = described_class.new(base_query: base_query, creator_id: user1.id).call
        # user1 created exactly these three in the setup.
        expect(result.to_a).to contain_exactly(@ts_recent_unbilled, @ts_without_group, @ts_different_project)
      end

      it 'ignoriert eine leere creator_id' do
        result = described_class.new(base_query: base_query, creator_id: '').call
        expect(result.count).to eq(5)
      end
    end

    describe 'Datumsbereich End-of-Day-Inklusivität' do
      it 'schließt Sessions am End-Datum NACH Mitternacht ein' do
        # 15:00 on `today` — a date-typed end bound would cast to today 00:00 and drop this.
        late = create(:time_session, project: project1, creator: user1,
                                     occurred_on: Time.current.change(hour: 15), duration: 30, billed: false)

        result = described_class.new(base_query: base_query,
                                     start_date: today.to_s, end_date: today.to_s).call

        expect(result.to_a).to include(late)
      end
    end

    describe 'Such-Filter' do
      context 'Suche nach Beschreibung' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            search: 'database'
          )
        end

        it 'filtert nach Beschreibungstext (case-insensitive)' do
          result = service.call
          expect(result.count).to eq(2)
          expect(result.to_a).to contain_exactly(@ts_recent_unbilled, @ts_old_billed)
        end
      end

      context 'Suche nach Ticket-Titel' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            search: 'Feature'
          )
        end

        it 'filtert nach Ticket-Titel' do
          result = service.call
          expect(result.count).to eq(1)
          expect(result.first).to eq(@ts_recent_unbilled)
        end
      end

      context 'Suche nach Gesprächs-Titel (meetings.title, Gespräche Slice 2)' do
        # A meeting-booked session must be findable by its meeting title — dropping
        # the `OR meetings.title ILIKE` term (or the left_joins(:meeting)) breaks this.
        let!(:meeting) do
          create(:meeting, project: project1, organisation: organisation, title: 'Kickoff Sanierung')
        end
        let!(:meeting_session) do
          create(:time_session,
                 project: project1,
                 meeting: meeting,
                 creator: user1,
                 occurred_on: today,
                 description: 'reine Notiz ohne Suchwort')
        end

        it 'findet die Session über den Gesprächs-Titel, nicht über die Beschreibung' do
          result = described_class.new(base_query: base_query, search: 'Sanierung').call
          expect(result.to_a).to contain_exactly(meeting_session)
        end

        it 'schließt Gesprächs-Sessions ohne Titel-Treffer aus' do
          result = described_class.new(base_query: base_query, search: 'Sanierung').call
          expect(result).not_to include(@ts_recent_unbilled, @ts_old_billed, @ts_without_group)
        end
      end

      # S6: the meeting's OWN filter. The title search above still exists and is
      # still useful, but it is not what a link from a meeting may rely on.
      context 'Bezugsfilter meeting_id (S6)' do
        let!(:meeting) do
          create(:meeting, project: project1, organisation: organisation, title: 'Kickoff Sanierung')
        end
        # THE case that made the title search dishonest: same title, same project,
        # two different meetings. The search answered with both.
        let!(:namesake) do
          create(:meeting, project: project1, organisation: organisation, title: 'Kickoff Sanierung')
        end
        let!(:meeting_session) do
          create(:time_session, project: project1, meeting: meeting, creator: user1, occurred_on: today)
        end
        let!(:namesake_session) do
          create(:time_session, project: project1, meeting: namesake, creator: user1, occurred_on: today)
        end

        it 'liefert nur die Zeiten DIESES Gesprächs, nicht die des gleichnamigen' do
          result = described_class.new(base_query: base_query, meeting_id: meeting.id).call

          expect(result.to_a).to contain_exactly(meeting_session)
        end

        it 'trennt, was die Titelsuche zusammenwirft' do
          by_title = described_class.new(base_query: base_query, search: 'Kickoff Sanierung').call
          by_id    = described_class.new(base_query: base_query, meeting_id: meeting.id).call

          expect(by_title.to_a).to contain_exactly(meeting_session, namesake_session)
          expect(by_id.to_a).to contain_exactly(meeting_session)
        end

        it 'schließt Ticket-Zeiten und Zeiten ohne Bezug aus' do
          result = described_class.new(base_query: base_query, meeting_id: meeting.id).call

          expect(result).not_to include(@ts_recent_unbilled, @ts_old_billed, @ts_without_group)
        end

        # Asked of the built SQL, not of the rows: "a blank value is no filter" is
        # a statement about the query, and TimeSessions::EmptyReason#narrows?
        # decides it the same way. It is also the sharper oracle -- a WHERE that
        # happens to match everything here would pass a row count.
        it 'ist ohne Wert kein Filter' do
          unfiltered = described_class.new(base_query: base_query).call.to_sql

          ['', '   ', nil].each do |blank|
            built = described_class.new(base_query: base_query, meeting_id: blank).call.to_sql

            expect(built).to eq(unfiltered), "meeting_id=#{blank.inspect} hat gefiltert"
          end
        end

        it 'findet zu einer Junk-Id nichts, statt sie zu ignorieren' do
          result = described_class.new(base_query: base_query, meeting_id: SecureRandom.uuid).call

          expect(result).to be_empty
        end

        # And the value that is NOT a uuid at all: Rails casts it to nil and
        # binds it, so the column is compared against NULL and matches
        # nothing. It does NOT become `IS NULL`, which would pull every booking
        # without a subject under a "one meeting" address.
        it 'findet auch zu einem Wert, der keine Uuid ist, nichts' do
          %w[abc 42 Kickoff].each do |junk|
            result = described_class.new(base_query: base_query, meeting_id: junk).call

            expect(result).to be_empty, "meeting_id=#{junk.inspect} hat gefiltert"
          end
        end

        # The two subject ids are separate columns and separate ANDs. Both set is
        # not an error to guard against, it is a query with no rows: a booking has
        # one subject or none.
        it 'UNDet die beiden Bezugs-Ids, statt eine gewinnen zu lassen' do
          result = described_class.new(base_query: base_query,
                                       meeting_id: meeting.id,
                                       ticket_id: @ts_recent_unbilled.ticket_id).call

          expect(result).to be_empty
        end
      end

      context 'Suche mit Leerzeichen' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            search: '  performance  '
          )
        end

        it 'trimmt Leerzeichen und sucht' do
          result = service.call
          expect(result.count).to eq(1)
          expect(result.first).to eq(@ts_old_billed)
        end
      end

      context 'Suche ohne Ergebnis' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            search: 'nonexistent'
          )
        end

        it 'gibt leeres Ergebnis zurück' do
          result = service.call
          expect(result.count).to eq(0)
        end
      end

      context 'Suche mit Sonderzeichen' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            search: '%_test'
          )
        end

        it 'behandelt SQL Wildcards sicher' do
          # Should not raise any error and not show unexpected behavior
          expect { service.call }.not_to raise_error
          result = service.call
          expect(result.count).to eq(0)
        end
      end
    end

    describe 'TimeSessionGroup-Filter' do
      context 'ungrouped' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            time_session_group_id: 'ungrouped'
          )
        end

        it 'filtert nach TimeSessions ohne Gruppe' do
          result = service.call
          expect(result.count).to eq(2)
          expect(result.to_a).to contain_exactly(@ts_without_group, @ts_no_ticket)
          expect(result.all? { |ts| ts.time_session_group.nil? }).to be true
        end
      end

      context 'spezifische Gruppe' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            time_session_group_id: group1.id.to_s
          )
        end

        it 'filtert nach spezifischer Gruppe' do
          result = service.call
          expect(result.count).to eq(2)
          expect(result.to_a).to contain_exactly(@ts_recent_unbilled, @ts_different_project)
          expect(result.all? { |ts| ts.time_session_group_id == group1.id }).to be true
        end
      end

      context 'nicht-existierende Gruppe' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            time_session_group_id: '00000000-0000-0000-0000-000000000000'
          )
        end

        it 'gibt leeres Ergebnis zurück' do
          result = service.call
          expect(result.count).to eq(0)
        end
      end
    end

    describe 'Kombinierte Filter (Integration Tests)' do
      context 'Projekt + Abrechnungsstatus' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            project_id_filter: project1.id.to_s,
            billing_status: 'unbilled'
          )
        end

        it 'wendet beide Filter an' do
          result = service.call
          expect(result.count).to eq(2)
          expect(result.to_a).to contain_exactly(@ts_recent_unbilled, @ts_without_group)
          expect(result.all? { |ts| ts.project_id == project1.id && !ts.billed? }).to be true
        end
      end

      context 'Ticket + Datum + Gruppe' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            ticket_id: ticket1.id.to_s,
            start_date: two_days_ago.to_s,
            time_session_group_id: group1.id.to_s
          )
        end

        it 'wendet alle drei Filter an' do
          result = service.call
          expect(result.count).to eq(1)
          expect(result.first).to eq(@ts_recent_unbilled)
        end
      end

      context 'Widersprüchliche Filter' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            billing_status: 'billed',
            time_session_group_id: 'ungrouped'
          )
        end

        it 'wendet beide Filter an (Schnittmenge)' do
          result = service.call
          expect(result.count).to eq(1)
          expect(result.first).to eq(@ts_no_ticket)
          expect(result.first.billed?).to be true
          expect(result.first.time_session_group).to be_nil
        end
      end

      context 'Filter die kein Ergebnis liefern' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            ticket_id: ticket1.id.to_s,
            billing_status: 'billed' # but ticket1 only has unbilled sessions
          )
        end

        it 'gibt leeres Ergebnis zurück' do
          result = service.call
          expect(result.count).to eq(0)
        end
      end

      context 'Alle Filter kombiniert' do
        let(:service) do
          described_class.new(
            base_query: base_query,
            project_id_filter: project1.id.to_s,
            ticket_id: ticket1.id.to_s,
            time_session_group_id: group1.id.to_s,
            billing_status: 'unbilled',
            start_date: two_days_ago.to_s,
            end_date: today.to_s,
            search: 'feature'
          )
        end

        it 'wendet alle Filter korrekt an' do
          result = service.call
          expect(result.count).to eq(1)
          expect(result.first).to eq(@ts_recent_unbilled)

          # Verification of all filter conditions
          ts = result.first
          expect(ts.project).to eq(project1)
          expect(ts.ticket).to eq(ticket1)
          expect(ts.time_session_group).to eq(group1)
          expect(ts.billed?).to be false
          expect(ts.occurred_on).to be_between(two_days_ago, today)
          expect(ts.description.downcase).to include('feature')
        end
      end
    end

    describe 'SQL Injection Sicherheit' do
      context 'mit bösartigen SQL-Zeichen in der Suche' do
        let(:malicious_searches) do
          [
            "'; DROP TABLE time_sessions; --",
            "' OR 1=1 --",
            "'; UPDATE time_sessions SET billed = true; --",
            "' UNION SELECT * FROM users --"
          ]
        end

        it 'ist sicher gegen SQL Injection' do
          # Pause Prosopite: the loop produces structurally identical COUNT queries
          # (one count per search term), which is falsely detected as N+1
          Prosopite.pause do
            malicious_searches.each do |malicious_search|
              service = described_class.new(
                base_query: base_query,
                search: malicious_search
              )

              result = service.call
              expect(result).to be_a(ActiveRecord::Relation)
              # Malicious SQL should not be executed as SQL
              expect(result.count).to eq(0)
            end
          end
        end
      end
    end

    describe 'Performance und Memory' do
      it 'gibt eine ActiveRecord::Relation zurück (lazy loading)' do
        service = described_class.new(base_query: base_query)
        result = service.call

        expect(result).to be_a(ActiveRecord::Relation)
        expect(result).not_to be_loaded
      end

      it 'führt keine N+1 Queries ein' do
        service = described_class.new(
          base_query: base_query,
          search: 'test'
        )

        # Ensure the query executes without N+1 issues
        # This would need a proper query counter, skipping for now
        expect { service.call.to_a }.not_to raise_error
      end
    end
  end

  describe '#parse_bound' do
    let(:service) { described_class.new(base_query: base_query) }

    context 'gültige Datumsformate' do
      it 'parst ein ISO-Datum auf den Tagesanfang (App-Zone) für die Start-Grenze' do
        result = service.send(:parse_bound, '2023-12-25', :beginning_of_day)
        expect(result).to eq(Time.zone.local(2023, 12, 25).beginning_of_day)
      end

      it 'parst ein ISO-Datum auf das TAGESENDE für die End-Grenze (Inklusivität)' do
        result = service.send(:parse_bound, '2023-12-25', :end_of_day)
        expect(result).to eq(Time.zone.local(2023, 12, 25).end_of_day)
      end

      it 'behandelt Schaltjahre korrekt' do
        result = service.send(:parse_bound, '2024-02-29', :beginning_of_day)
        expect(result).to eq(Time.zone.local(2024, 2, 29).beginning_of_day)
      end
    end

    context 'ungültige Eingaben' do
      it 'gibt nil für leere oder nil-Eingabe zurück' do
        expect(service.send(:parse_bound, '', :beginning_of_day)).to be_nil
        expect(service.send(:parse_bound, nil, :end_of_day)).to be_nil
      end

      it 'gibt nil für nicht parsebare Strings zurück' do
        ['invalid-date', 'not-a-date'].each do |junk|
          expect(service.send(:parse_bound, junk, :beginning_of_day)).to be_nil
        end
      end

      it 'gibt nil zurück und loggt eine Warnung bei einem ungültigen Datum' do
        expect(Rails.logger).to receive(:warn).with(/Invalid date format/i)
        expect(service.send(:parse_bound, '2023-13-45', :beginning_of_day)).to be_nil
      end
    end
  end

  describe 'Service Initialization' do
    it 'funktioniert mit minimalen Parametern' do
      expect { described_class.new(base_query: base_query) }.not_to raise_error
    end

    it 'akzeptiert alle erwarteten Parameter' do
      expect do
        described_class.new(
          base_query: base_query,
          project: project1,
          project_id_filter: 'some-id',
          ticket_id: 'some-id',
          time_session_group_id: 'some-id',
          start_date: '2023-01-01',
          end_date: '2023-12-31',
          billing_status: 'unbilled',
          search: 'test',
          smart_folder: nil
        )
      end.not_to raise_error
    end

    it 'erfordert base_query Parameter' do
      expect { described_class.new }.to raise_error(ArgumentError, /base_query/)
    end
  end

  # Handout §3.4: the search covers description, subject title, subject ID and
  # billing name. The first two were there; the last two are new (02.09.2026).
  describe 'what the search reaches' do
    let(:numbered) { create(:ticket, project: project1, title: 'Fundament') }
    let(:named_group) { create(:time_session_group, organisation: organisation, name: 'webapp2-sep-2026') }

    def found(term)
      described_class.new(base_query: TimeSession.all, search: term).call.to_a
    end

    it 'finds a booking by its ticket NUMBER, exactly and not as a substring' do
      # ⚠️ A TWO-DIGIT number on purpose. The factory assigns 1, and against 1 a
      # substring search and an exact one give the same answer for every query --
      # the first version of this example passed just as happily against a LIKE
      # on the cast, which is the very thing it claims to forbid.
      numbered.update_column(:number, 89)
      hit = create(:time_session, organisation: organisation, project: project1, creator: user1,
                                  duration: 60, occurred_on: today, ticket: numbered,
                                  description: 'nichts hilfreiches')

      expect(found('89')).to include(hit)
      # "8" is a prefix of 89 and a LIKE would answer with it. A number is asked
      # as a number, or the result looks like a search and is not one.
      expect(found('8')).not_to include(hit)
      expect(found('9')).not_to include(hit)
    end

    it 'accepts the number with the # people write in front of it' do
      hit = create(:time_session, organisation: organisation, project: project1, creator: user1,
                                  duration: 60, occurred_on: today, ticket: numbered)

      expect(found("##{numbered.number}")).to include(hit)
    end

    it 'finds a booking by the name of the billing it sits in' do
      hit = create(:time_session, organisation: organisation, project: project1, creator: user1,
                                  duration: 60, occurred_on: today, time_session_group: named_group,
                                  description: 'nichts hilfreiches')

      expect(found('webapp2-sep')).to include(hit)
    end

    # ⚠️ The joins are LEFT joins for this reason: a booking with no subject and
    # no billing must still be reachable by its own description, and an inner
    # join would have dropped it the moment the search touched those tables.
    it 'still finds a booking that has neither subject nor billing' do
      bare = create(:time_session, organisation: organisation, project: project1, creator: user1,
                                   duration: 60, occurred_on: today, description: 'Serverwartung')

      expect(found('Serverwartung')).to include(bare)
    end
  end

  # The tag filter (step 2 of doc/zeiten_weitere_filter_plan.md, variant C): a
  # booking matches when the tag is on the booking OR on its ticket.
  describe 'tag_id' do
    let(:tag) { create(:tag, organisation: organisation, name: 'kunde-a') }
    let(:ticket) { create(:ticket, project: project1, organisation: organisation) }

    def booking(**attrs)
      create(:time_session, project: project1, creator: user1, duration: 30, occurred_on: today, **attrs)
    end

    def tagged(record)
      create(:tagging, tag: tag, taggable: record)
      record
    end

    def filtered(tag_id = tag.id)
      described_class.new(base_query: TimeSession.all, tag_id: tag_id).call
    end

    it 'finds a booking that carries the tag itself' do
      own = tagged(booking)

      expect(filtered).to contain_exactly(own)
    end

    it 'finds a booking whose ticket carries the tag' do
      tagged(ticket)
      on_ticket = booking(ticket: ticket)

      expect(filtered).to contain_exactly(on_ticket)
    end

    # Either side alone is a different filter: the session side alone misses
    # every ticket tag, the ticket side alone every booking without a ticket.
    it 'finds both kinds together, and nothing untagged' do
      own = tagged(booking)
      tagged(ticket)
      on_ticket = booking(ticket: ticket)
      booking
      booking(ticket: create(:ticket, project: project1, organisation: organisation))

      expect(filtered).to contain_exactly(own, on_ticket)
    end

    # A join would list a booking twice when both sides carry the tag, and the
    # sum over the list would count its minutes twice.
    it 'lists a booking once when it and its ticket both carry the tag' do
      tagged(ticket)
      both = tagged(booking(ticket: ticket))

      expect(filtered.to_a).to eq([both])
      expect(TimeSession.where(id: filtered.reorder(nil).select(:id)).sum(:duration)).to eq(30)
    end

    it 'ignores the tag on anything else that is tagged' do
      tagged(booking)
      other_tag = create(:tag, organisation: organisation, name: 'kunde-b')
      create(:tagging, tag: other_tag, taggable: booking)

      expect(filtered(other_tag.id).map(&:tag_list)).to eq([['kunde-b']])
    end

    # An id the uuid type rejects is still a filter: it matches nothing
    # instead of switching itself off.
    it 'matches nothing for an id that is no uuid' do
      tagged(booking)

      expect(filtered('junk')).to be_empty
    end

    it 'leaves the list alone without a tag' do
      expect(filtered(nil).count).to eq(TimeSession.count)
    end
  end

  # The ticket phase (step 3a of doc/zeiten_weitere_filter_plan.md): the phase
  # of the booking's ticket, read from the status System Functions of the
  # projects in the list. A booking without a ticket has no phase.
  describe 'ticket_phase' do
    before do
      create(:ticket_attribute_definition,
             project: project1, name: 'status', field_type: 'select', system: true,
             options: { 'allowed_values' => [
               { 'value' => 'Offen', 'system_functions' => ['is_open'] },
               { 'value' => 'Liegt', 'system_functions' => ['is_backlog'] },
               { 'value' => 'Fertig', 'system_functions' => ['is_completed'] }
             ] })
    end

    def ticket_in(status)
      create(:ticket, project: project1, organisation: organisation).tap do |record|
        record.update_column(:custom_attributes, { 'status' => status })
      end
    end

    def booking(**attrs)
      create(:time_session, project: project1, creator: user1, duration: 30, occurred_on: today, **attrs)
    end

    def filtered(phase, readable: Ticket.all)
      described_class.new(base_query: TimeSession.where(project: project1), ticket_phase: phase,
                          readable_tickets: readable).call
    end

    let!(:on_done)    { booking(ticket: ticket_in('Fertig')) }
    let!(:on_open)    { booking(ticket: ticket_in('Offen')) }
    let!(:on_backlog) { booking(ticket: ticket_in('Liegt')) }
    let!(:no_subject) { booking }

    it 'finds the bookings on tickets of each phase' do
      expect(filtered('done')).to contain_exactly(on_done)
      expect(filtered('backlog')).to contain_exactly(on_backlog)
    end

    # E4: a booking without a ticket drops out, even from "in progress".
    it 'leaves out bookings without a ticket in every phase' do
      expect(filtered('active')).not_to include(no_subject)
      expect(filtered('active')).to include(on_open)
    end

    it 'matches nothing for a phase it does not know' do
      expect(filtered('junk')).to be_empty
    end

    it 'leaves the list alone without a phase' do
      expect(filtered(nil)).to include(on_done, on_open, on_backlog, no_subject)
    end

    # A phase reads a ticket's status, so only tickets the reader may open
    # count. A booking on any other ticket is treated like one without.
    it 'reads only the tickets it is handed as readable' do
      expect(filtered('done', readable: Ticket.where.not(id: on_done.ticket_id))).to be_empty
      expect(filtered('done', readable: Ticket.where(id: on_done.ticket_id))).to contain_exactly(on_done)
    end

    # Fail closed: a caller that forgets the readable tickets gets nothing,
    # never every ticket's status.
    it 'finds nothing when no readable tickets are handed in' do
      expect(filtered('done', readable: nil)).to be_empty
    end
  end

  # One concrete status value of the booking's ticket (step 3b): matched
  # exactly, only on readable tickets, bookings without a ticket drop out.
  describe 'ticket_status' do
    def ticket_in(status)
      create(:ticket, project: project1, organisation: organisation).tap do |record|
        record.update_column(:custom_attributes, { 'status' => status })
      end
    end

    def booking(**attrs)
      create(:time_session, project: project1, creator: user1, duration: 30, occurred_on: today, **attrs)
    end

    def filtered(value, readable: Ticket.all, **more)
      described_class.new(base_query: TimeSession.where(project: project1), ticket_status: value,
                          readable_tickets: readable, **more).call
    end

    let!(:on_done)    { booking(ticket: ticket_in('Fertig')) }
    let!(:on_open)    { booking(ticket: ticket_in('Offen')) }
    let!(:no_subject) { booking }

    # Exactly, like the ticket table: no case folding, which Ruby and
    # Postgres do differently (LOWER leaves "Ü" alone under LC_CTYPE=C).
    it 'finds the bookings on tickets with exactly that value' do
      expect(filtered('Fertig')).to contain_exactly(on_done)
      expect(filtered('fERTIG')).to be_empty
    end

    # A number in the JSON is the same value as its text in the menu.
    it 'finds a value stored as a number by its text' do
      on_number = booking(ticket: ticket_in(1))

      expect(filtered('1')).to contain_exactly(on_number)
    end

    it 'finds a value with a non-ASCII capital' do
      on_review = booking(ticket: ticket_in('Überprüfung'))

      expect(filtered('Überprüfung')).to contain_exactly(on_review)
    end

    it 'matches nothing for a value no ticket carries' do
      expect(filtered('Fert')).to be_empty
    end

    it 'leaves the list alone without a value' do
      expect(filtered(nil)).to include(on_done, on_open, no_subject)
    end

    it 'reads only the tickets it is handed as readable' do
      expect(filtered('Fertig', readable: Ticket.where.not(id: on_done.ticket_id))).to be_empty
    end

    it 'finds nothing when no readable tickets are handed in' do
      expect(filtered('Fertig', readable: nil)).to be_empty
    end

    # Both typed at once is no menu's doing; the two narrow like any two filters.
    it 'narrows together with a phase' do
      expect(filtered('Offen', ticket_phase: 'done')).to be_empty
    end
  end
end
