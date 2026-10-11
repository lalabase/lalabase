# frozen_string_literal: true

require 'rails_helper'

# What: the mechanisms that hold up the promises lalabase.com makes about this product.
# Why:  the feature pages describe the product to people who have not signed anything.
#   Until W3 those pages lived here and one example could say both halves at once: "the
#   page says there is no stopwatch" AND "TimeSession has no clock columns". The pages
#   are in gboyke/lalabase-website now, and an example cannot reach both sides any more.
#
#   So the claim is split where it always was two statements. The SENTENCE is pinned
#   over there (spec/requests/static/features_spec.rb in the website). The MECHANISM is
#   pinned here, with the sentence quoted so a red run says what is now untrue in public.
#
#   Split from spec/requests/static/features_spec.rb on 19.09.2026 (W3.6). That file
#   keeps the sentence halves while the core still serves its own copies of the pages,
#   and goes away with them at W6. This guard does not.
#
# A red run here is never only a code question. Either the change is wrong, or a
# sentence on a public page has just become false and has to be rewritten there.
RSpec.describe 'Mechanisms behind the claims on lalabase.com' do
  describe 'the overview' do
    # "Aufgaben lesen, anlegen und kommentieren, Status, Zuweisung und Titel ändern, Zeit
    # auf Aufgaben buchen und Benachrichtigungen als gelesen markieren. Kein Löschen von
    # außen." Three sentences enumerate the MCP set's write surface: the tasks line of the
    # overview, the FAQ of the tasks chapter and the FAQ of the development page. A tool
    # added here makes all three incomplete, one removed makes them a false promise. The
    # inbox workflow (#617) added two writes and all three went on naming the first two
    # until 10.09.2026. update_ticket (terminal client S2) ended the promise "no status
    # changes from outside" in two FAQ answers; the sentence that still holds is "no
    # deleting from outside".
    it 'has exactly the five mutating MCP tools those sentences enumerate' do
      mutating = Lalabase::Tools::Registry.for(:mcp).select(&:mutating?)

      expect(mutating.map(&:name)).to match_array(
        %w[Lalabase::Tools::CreateTicket Lalabase::Tools::PostComment
           Lalabase::Tools::CreateTimeSession Lalabase::Tools::MarkNotificationRead
           Lalabase::Tools::UpdateTicket]
      )
    end

    # "Abgerechnet wird die einzelne Sitzung, nicht das Ticket." The partial-billing
    # claim rests on billing granularity being the SESSION. If `billed` ever moved to
    # Ticket, "keep working on a task billed long ago" would stop being true.
    it 'keeps the billed flag on the session, not on the ticket' do
      expect(TimeSession.column_names).to include('billed')
      expect(Ticket.column_names).not_to include('billed')
    end

    # "kein Zugriff, nur lesen oder schreiben" is the reader's answer to "my client only
    # wants to search". It is the enum, so it is countable.
    #
    # Read from `defined_enums`, NOT from ProjectPermission.tickets_accesses: that method
    # is hand-overridden at the bottom of the model with a duplicated literal hash, so it
    # shadows the enum Rails generates. A pin on it went green with `read_only` deleted
    # from the actual enum -- verified by mutation, which is the only reason this is not
    # still a blind assertion.
    it 'offers exactly the three ticket access levels the page names' do
      expect(ProjectPermission.defined_enums['tickets_access'].keys).to eq(%w[no_access read_only read_write])
    end

    # "OpenAI, Anthropic, Google oder an einem OpenAI-kompatiblen Endpunkt." A fifth
    # provider type added to the model makes that list silently incomplete in public.
    it 'supports exactly the four credential providers the page names' do
      expect(AiCredential::PROVIDERS.size).to eq(4)
    end

    # "Fünf Rechtsraum-Stufen" is a countable claim.
    it 'carries exactly the five jurisdiction tiers the page counts' do
      expect(AiPackage::JURISDICTIONS.size).to eq(5)
    end

    # "belegt keinen bezahlten Platz." A pricing promise that holds only because a
    # non-billable role records no seat. Asserted on the observable SeatEvent row rather
    # than the private #seat_counted?, and WITH the billable contrast -- the absence
    # alone would go vacuum-green if seat recording broke entirely, which is the one case
    # where the page would still read fine while the billing underneath had stopped.
    it 'records no seat for a non-billable role, and one for a billable role' do
      organisation = create(:organisation)

      ActsAsTenant.with_tenant(organisation) do
        guest_role = create(:role, organisation: organisation, billable: false)
        paid_role  = create(:role, organisation: organisation, billable: true)

        expect { create(:membership, organisation: organisation, role: guest_role) }
          .not_to change(SeatEvent, :count)
        expect { create(:membership, organisation: organisation, role: paid_role) }
          .to change(SeatEvent, :count).by(1)
      end
    end

    # The page invites the reader to run one organisation per client, so the obvious next
    # promise is "a person in several of them is one paid seat". SeatCounter DOES dedup
    # that way -- but only within ONE Account, and AccountAutoAssignable gives every newly
    # created organisation its OWN account. Self-service, one organisation per client
    # therefore means one account per client, and the promise would be false.
    #
    # The website pins the ABSENCE of that sentence. This pins the cause, so the day
    # organisations start sharing the creator's account it goes red and asks for the copy
    # it then earns.
    #
    # The dedup itself is real and already pinned where it belongs:
    # spec/services/subscriptions/seat_counter_spec.rb. Deliberately NOT repeated here.
    it 'gives every newly created organisation its own account' do
      first  = create(:organisation)
      second = create(:organisation)

      expect(first.account).to be_present
      expect(second.account).to be_present
      expect(second.account_id).not_to eq(first.account_id)
    end
  end

  describe 'the time chapter' do
    # "Keine Stoppuhr. Du trägst Datum und Dauer ein, es läuft keine Uhr im Hintergrund."
    # The honest half of the page, and the one that turns into a lie the day someone adds
    # a running timer without reading it.
    it 'has no running clock on a time session' do
      clock_columns = TimeSession.column_names.grep(/start|running|stopped|timer/)

      expect(clock_columns).to be_empty,
                               'lalabase.com says there is no stopwatch, but TimeSession ' \
                               "carries #{clock_columns.join(', ')}."
    end

    # "Keine Beträge. Lalabase kennt keine Stundensätze und schreibt keine Rechnung."
    # Also the mechanism behind the overview's "abrechnungsreife Position, nicht
    # Rechnungen erstellen": TimeSessionGroup prepares, it does not invoice.
    it 'carries no money on sessions or groups, and has no invoice at all' do
      money = (TimeSession.column_names + TimeSessionGroup.column_names)
              .grep(/rate|amount|price|cents|currency/)

      expect(money).to be_empty, "Money columns appeared: #{money.join(', ')}"
      expect(defined?(Invoice)).to be_nil, 'An Invoice model exists; lalabase.com says we write none.'
    end

    # "Ab da sind ihre Sitzungen schreibgeschützt." Proven against the validation itself,
    # not against its presence in a comment: a billed session must actually refuse an edit.
    it 'refuses an edit to a billed session' do
      organisation = create(:organisation)

      ActsAsTenant.with_tenant(organisation) do
        session = create(:time_session, organisation: organisation)
        session.update!(billed: true)

        session.description = 'nachtraeglich geaendert'

        expect(session).not_to be_valid
        expect(session.errors[:base]).to be_present
      end
    end

    # "Sieben Schalter je Rolle regeln das." A number in marketing copy that nobody
    # recounts once it is written.
    it 'offers exactly seven permission switches' do
      switches = TimeSessionPermission.column_names.grep(/\Acan_/)

      expect(switches.size).to eq(7), "The model offers #{switches.size}: #{switches.join(', ')}"
    end

    # "Voreingestellt ist, dass jeder seine eigenen Zeiten anlegt und sieht, fremde nicht."
    it 'defaults to everyone seeing their own times and no one else\'s' do
      defaults = TimeSessionPermission.column_defaults

      expect(defaults['can_create_own']).to be(true)
      expect(defaults['can_view_own']).to be(true)
      expect(defaults['can_view_all']).to be(false)
      expect(defaults['can_edit_all']).to be(false)
      expect(defaults['can_delete_all']).to be(false)
    end

    # "Als CSV-Datei ... mit Datum, Ticketnummer, Betreff, interner Beschreibung,
    # Kundenbeschreibung und Dauer. Semikolon-getrennt."
    it 'writes the export with six columns, semicolon separated' do
      exporter = Rails.root.join('app/controllers/organisations/time_session_groups_controller.rb').read

      expect(exporter).to include("col_sep: ';'")
      expect(exporter.scan(/customer_export\.csv\.\w+/).uniq.size).to eq(6)
    end

    # "Zeit, die an einem Meeting hängt, hat keine Ticketnummer, und dann bleibt die
    # Spalte leer statt eine Nummer zu erfinden." Pinned because it is the sort of detail
    # a later convenience fix ("just put the meeting id in there") undoes.
    it 'gives a meeting no number that could be invented into that column' do
      expect(Meeting.column_names).not_to include('number')
    end
  end

  describe 'the other chapters' do
    # "Unteraufgaben gehen genau eine Ebene tief."
    it 'refuses a second level of sub-tasks' do
      organisation = create(:organisation)

      ActsAsTenant.with_tenant(organisation) do
        project = create(:project, organisation: organisation)
        parent = create(:ticket, project: project, organisation: organisation)
        child = create(:ticket, project: project, organisation: organisation, parent: parent)

        grandchild = build(:ticket, project: project, organisation: organisation, parent: child)

        expect(grandchild).not_to be_valid
      end
    end

    # Was: "Darüber hinaus gibt es keine Beziehungen zwischen Aufgaben.", held by "no relation
    # table". Ticket relations exist since PR 1 of doc/ticket_relations_plan.md (revision 4),
    # and PR 2 shows them on the ticket page; the website sentence is rewritten with PR 2 (its
    # features_spec pins it there). What the new sentence may promise, and what this example
    # holds: four kinds, and a delay in days that is stored and shown but never moves a date,
    # since Lalabase has no start date to move.
    it 'relates tickets in four kinds and moves no date because of a delay' do
      expect(TicketRelation.relation_types.keys).to eq(%w[blocks relates_to duplicates precedes])

      sources = Dir[Rails.root.join('{app,lib}/**/*.rb')].map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      readers = sources.select do |path|
        Rails.root.join(path).each_line.any? { |line| !line.lstrip.start_with?('#') && line.include?('delay_days') }
      end
      # The controller hands the typed value to the actor, the section shows it: neither
      # computes with it.
      expect(readers).to contain_exactly('app/models/ticket_relation.rb', 'app/services/actors/create_ticket_relation.rb',
                                         'app/controllers/organisations/tickets/relations_controller.rb',
                                         'app/services/tickets/relation_section.rb'),
                         "New code reads delay_days: #{readers.sort.join(', ')}. Showing it is fine, computing a date " \
                         'from it breaks the promise. Add the file here once you are sure it only shows the value.'
    end

    # "Er liest, er schreibt nicht." The chat surface must carry no mutating tool -- that
    # separation is a hard rule of the registry, and the page now sells it.
    #
    # Asked over CHAT_SETS since projekt_chat_abbau removed :project_chat: the promise is
    # about the CHAT surface, and every set that reaches the LLM tool loop is that surface.
    it 'keeps every chat tool set free of a writer, while the MCP set has them' do
      Lalabase::Tools::Registry::CHAT_SETS.each do |set|
        expect(Lalabase::Tools::Registry.for(set)).not_to include(Lalabase::Tools::CreateTicket)
        expect(Lalabase::Tools::Registry.for(set)).not_to include(Lalabase::Tools::PostComment)
      end
      expect(Lalabase::Tools::Registry.for(:mcp))
        .to include(Lalabase::Tools::CreateTicket, Lalabase::Tools::PostComment)
    end

    # "Nur GitHub und GitLab."
    it 'accepts exactly the two repository providers the page names' do
      expect(ProjectRepository::PROVIDERS).to contain_exactly('github', 'gitlab')
    end

    # "Im Auslieferungszustand ist ein Gespräch nicht durchsuchbar." The sentence is about
    # a DEFAULT, and a default is one migration away from being the opposite.
    it 'leaves a meeting unsearchable by default' do
      expect(Meeting.column_defaults['create_embeddings']).to be(false)
    end

    # "Ein Projekt gehört genau einer Organisation."
    it 'ties a project to exactly one organisation' do
      expect(Project.reflect_on_association(:organisation).macro).to eq(:belongs_to)
      expect(Project.reflect_on_association(:organisations)).to be_nil
    end
  end
end
