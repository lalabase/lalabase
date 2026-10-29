# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Neo::Chat::CitationListComponent, type: :component do
  # The list now renders inside a collapsed <details> (sources hidden until the
  # user clicks). Capybara ignores hidden elements by default; these specs assert
  # on the rendered STRUCTURE regardless of the collapsed state.
  around do |example|
    previous = Capybara.ignore_hidden_elements
    Capybara.ignore_hidden_elements = false
    example.run
  ensure
    Capybara.ignore_hidden_elements = previous
  end

  def vision_cite(id: 'vid-1')
    { 'type' => 'vision', 'id' => id }
  end

  def capability_cite(name: 'Notifications', id: 'cid-1')
    { 'type' => 'capability', 'id' => id, 'name' => name }
  end

  def symbol_cite(qn: 'Foo#bar', path: 'app/foo.rb', start_line: 10, end_line: 25, id: 'sid-1')
    {
      'type' => 'symbol', 'id' => id, 'qualified_name' => qn,
      'file_path' => path, 'start_line' => start_line, 'end_line' => end_line
    }
  end

  def render_with(citations)
    render_inline(described_class.new(citations: citations))
  end

  describe 'render?' do
    it 'renders nothing for an empty array' do
      render_with([])
      expect(rendered_content).to eq('')
    end

    it 'renders nothing for nil citations (defense in depth)' do
      render_with(nil)
      expect(rendered_content).to eq('')
    end

    it 'renders when at least one citation is present' do
      render_with([vision_cite])
      expect(rendered_content).not_to eq('')
    end

    it 'renders nothing when a Hash is passed instead of an Array (defensive)' do
      render_with({ 'type' => 'vision', 'id' => 'x' })
      expect(rendered_content).to eq('')
    end

    it 'renders nothing when a String is passed instead of an Array (defensive)' do
      render_with('not an array')
      expect(rendered_content).to eq('')
    end

    it 'silently drops nil items inside the array (does not crash)' do
      expect { render_with([nil, vision_cite, nil]) }.not_to raise_error
      expect(page).to have_css('ul li', count: 1)
    end

    it 'silently drops non-Hash items inside the array (does not crash)' do
      expect { render_with([42, 'string', [1, 2], vision_cite]) }.not_to raise_error
      expect(page).to have_css('ul li', count: 1)
    end

    it 'renders nothing when ALL items are non-Hash (no orphan header)' do
      render_with([42, nil, 'string'])
      expect(rendered_content).to eq('')
    end
  end

  describe 'header' do
    it 'shows the localised header' do
      render_with([vision_cite])
      expect(rendered_content).to include(I18n.t('views.organisations.chats.citations.header'))
    end
  end

  describe 'vision citation' do
    it 'renders the vision label' do
      render_with([vision_cite])
      expect(rendered_content).to include(I18n.t('views.organisations.chats.citations.vision'))
    end

    it 'shows the vision icon (bi-eye)' do
      render_with([vision_cite])
      expect(page).to have_css('.bi-eye')
    end
  end

  describe 'capability citation' do
    it "renders the capability's name" do
      render_with([capability_cite(name: 'NotificationFanout')])
      expect(rendered_content).to include('NotificationFanout')
    end

    it 'shows the capability icon (bi-puzzle)' do
      render_with([capability_cite])
      expect(page).to have_css('.bi-puzzle')
    end

    it 'escapes HTML inside the capability name (XSS safety)' do
      render_with([capability_cite(name: '<script>alert(1)</script>')])
      expect(rendered_content).not_to include('<script>alert(1)</script>')
      expect(rendered_content).to include('&lt;script&gt;')
    end
  end

  describe 'symbol citation' do
    it 'renders the qualified_name and file:line location' do
      render_with([symbol_cite(qn: 'NotificationFanout#call', path: 'app/x.rb', start_line: 42)])
      expect(rendered_content).to include('NotificationFanout#call')
      expect(rendered_content).to include('app/x.rb:42')
    end

    it 'shows the symbol icon (bi-braces)' do
      render_with([symbol_cite])
      expect(page).to have_css('.bi-braces')
    end

    it 'does NOT render the location line when file_path is blank' do
      render_with([symbol_cite(path: '')])
      # Location helper returns nil → no extra location line. The label still
      # renders the qualified_name.
      expect(rendered_content).to include('Foo#bar')
      expect(rendered_content).not_to include(':10')
    end
  end

  describe 'unknown citation type — forward compatibility' do
    it 'renders an unknown citation with the fallback label and icon (does not crash)' do
      render_with([{ 'type' => 'future_thing', 'id' => 'x' }])
      # Check the label span EXACTLY, not include() over the whole HTML: the list header "Quellen"
      # contains "Quelle" as a substring → a plain include() would be tautologically always green.
      labels = page.all('li .font-medium').map(&:text)
      expect(labels).to include(I18n.t('views.organisations.chats.citations.unknown'))
      expect(page).to have_css('.bi-bookmark')
    end
  end

  describe 'mixed citation list ordering' do
    it 'renders citations in the order they were passed' do
      render_with([symbol_cite(qn: 'A#first'), vision_cite, capability_cite(name: 'Last')])
      a = rendered_content.index('A#first')
      b = rendered_content.index(I18n.t('views.organisations.chats.citations.vision'))
      c = rendered_content.index('Last')
      expect([a, b, c]).to eq([a, b, c].sort)
    end
  end

  # S3c T3: the panel address on a source chip (plan §4, §8.1). Only sources that
  # HAVE a panel carry one; everything else keeps navigating to its own page, and
  # the assistant panel's click handler sees nothing to intercept.
  describe 'the artefact address (S3c T3)' do
    let(:organisation) { create(:organisation) }
    let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

    # Stringified on purpose: a citation reaches this component out of JSONB, so
    # symbol keys here would test a shape production never produces.
    def render_time_report(filters:)
      render_inline(described_class.new(
                      citations: [Lalabase::Citations.time_report(project, filters).deep_stringify_keys],
                      organisation: organisation
                    ))
    end

    it 'carries kind and project on a time report' do
      render_time_report(filters: {})

      link = page.find('li a')
      query = Rack::Utils.parse_nested_query(link['data-assistant-artefact'])
      expect(query).to eq('kind' => 'report', 'project_id' => project.id)
    end

    it 'carries the frozen filters, so the panel shows the set the answer counted' do
      render_time_report(filters: { start_date: '2026-05-01', ticket_id: 'abc' })

      query = Rack::Utils.parse_nested_query(page.find('li a')['data-assistant-artefact'])
      expect(query).to include('start_date' => '2026-05-01', 'ticket_id' => 'abc')
    end

    it 'leaves a source WITH a page of its own without one' do
      # A REAL ticket since Feinschliff B: a citation whose target is gone renders
      # as text, and this example is about the artefact attribute on a link.
      ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation) }
      render_inline(described_class.new(
                      citations: [{ 'type' => 'ticket', 'id' => ticket.id,
                                    'project_id' => project.id, 'number' => 7, 'title' => 'T' }],
                      organisation: organisation
                    ))

      expect(page.find('li a')['data-assistant-artefact']).to be_nil
    end

    it 'omits it when the citation carries no project (a link cannot be built either)' do
      render_inline(described_class.new(
                      citations: [{ 'type' => 'time_report', 'id' => 'x', 'filters' => {} }],
                      organisation: organisation
                    ))

      expect(page).to have_no_css('li a')
    end
  end

  describe 'constants locked as contract' do
    it {
      expect(described_class::KNOWN_TYPES)
        .to contain_exactly('vision', 'capability', 'symbol', 'ticket', 'note', 'document', 'post', 'documentation', 'meeting', 'meeting_analysis',
                            'time_report', 'help_page', 'person')
    }
    it { expect(described_class::KNOWN_TYPES).to be_frozen }
    it { expect(described_class::ICON_MAP).to be_frozen }
    it { expect(described_class::ICON_MAP.keys.sort).to eq(described_class::KNOWN_TYPES.sort) }
    it { expect(described_class::FALLBACK_ICON).to eq('bi-bookmark') }
  end

  describe 'producer↔renderer label contract: every Citations::TYPES entry has a real label' do
    # Drift guard via the CONSTANT (not hardcoded individual tests): a type that the producer
    # (Citations::TYPES) lists as known must NOT fall through to the unknown label.
    # ICON_MAP.keys==TYPES is pinned separately; this adds the label half. A new
    # producer type without a label_for branch breaks HERE, instead of silently degrading to "unknown".
    # The taxonomy has one owner since 12.09.2026 (Lalabase::Citations): area-bearing content,
    # the area-less code layer, and Lalabase's own texts, which are area-less with a page.
    content_types = Lalabase::Citations::CONTENT_TYPES
    code_types    = Lalabase::Citations::CODE_TYPES
    product_types = Lalabase::Citations::PRODUCT_TYPES

    it 'accounts for EVERY KNOWN_TYPES entry in the content/code/product taxonomy (no orphan type)' do
      expect((content_types + code_types + product_types).sort).to eq(described_class::KNOWN_TYPES.sort)
    end

    described_class::KNOWN_TYPES.each do |type|
      it "renders a NON-unknown label for the known producer type #{type}" do
        # Via render_inline (label_for calls t(), which needs the render context). An
        # over-specified hash covers the fields of every type. The label span is checked
        # EXACTLY (not as a substring over the whole HTML — the list header "Quellen" contains "Quelle"):
        # a known type must not fall onto the unknown fallback ("Quelle"/"Source").
        citation = { 'type' => type, 'id' => 'x', 'name' => 'Caps', 'qualified_name' => 'Foo#bar',
                     'number' => 1, 'title' => 'Titel', 'ticket_number' => 1, 'project_id' => 'p',
                     'ticket_id' => 't', 'file_path' => 'a.rb', 'start_line' => 1 }
        render_inline(described_class.new(citations: [citation]))
        labels = page.all('li .font-medium').map(&:text)
        expect(labels).to be_present
        expect(labels).not_to include(I18n.t('views.organisations.chats.citations.unknown'))
      end
    end
  end

  describe 'icon mapping — hardcoded expectations (catches a swap, unlike iterating ICON_MAP)' do
    # Expectations are LITERAL, NOT read from ICON_MAP. Iterating ICON_MAP would draw both
    # the input type AND the expected icon from the same source, so a swap of two entries
    # (e.g. vision↔capability) moves both together and passes — exactly the bug this guards.
    # Hardcoding makes a swap break a test. (ICON_MAP.keys == KNOWN_TYPES is pinned separately,
    # so coverage of "every type has an icon" is not lost.)
    {
      'vision' => 'bi-eye',
      'capability' => 'bi-puzzle',
      'symbol' => 'bi-braces',
      'ticket' => 'bi-card-checklist',
      'note' => 'bi-journal-text',
      'document' => 'bi-file-earmark-text',
      'post' => 'bi-chat-square-quote',
      'documentation' => 'bi-book',
      'meeting' => 'bi-chat-quote',
      'meeting_analysis' => 'bi-magic',
      'time_report' => 'bi-stopwatch',
      'help_page' => 'bi-question-circle',
      'person' => 'bi-person'
    }.each do |type, icon|
      it "renders the literal icon #{icon} for a #{type} citation" do
        render_with([{ 'type' => type, 'id' => 'x' }])
        expect(page).to have_css(".#{icon}")
      end
    end
  end

  describe "a page of Lalabase's own help (product knowledge S2)" do
    let(:help_org) { create(:organisation) }
    let(:help_cite) do
      { 'type' => 'help_page', 'source' => 'help', 'id' => 'guides/features/time-tracking',
        'locale' => 'de', 'title' => 'Zeiterfassung' }
    end

    # The frame escape matters most here: get_help_page keeps /hilfe links out of the answer
    # text precisely because a link without it opens inside the chat frame ("Content missing").
    it 'links to /hilfe by slug without a project, out of the chat frame, and is never called gone' do
      I18n.with_locale(:de) { render_inline(described_class.new(citations: [help_cite], organisation: help_org)) }

      link = page.find('li a')
      expect(link[:href]).to eq('/hilfe/guides/features/time-tracking')
      expect(link[:'data-turbo-frame']).to eq('_top')
      expect(link.text).to eq('Hilfe: Zeiterfassung')
      expect(page).to have_no_css('[data-testid="citation-gone"]')
    end

    # Literal, not I18n.t: with the German fallback a missing English key would still pass.
    it 'labels it in English for an English reader' do
      I18n.with_locale(:en) { render_inline(described_class.new(citations: [help_cite], organisation: help_org)) }

      expect(page.find('li a').text).to eq('Help: Zeiterfassung')
    end
  end

  # People S3: a person of the directory. No project; the link opens the people page with
  # the person in the lane, a contact by its row, a member by the account.
  describe 'a person of the people directory (People S3)' do
    let(:person_org) { create(:organisation) }

    before { ActsAsTenant.current_tenant = person_org }
    after  { ActsAsTenant.current_tenant = nil }

    def render_person(cite)
      render_inline(described_class.new(citations: [cite], organisation: person_org))
    end

    def people_path(**lane)
      Rails.application.routes.url_helpers.organisation_people_path(person_org, **lane)
    end

    it 'names a contact and links its row, out of the chat frame' do
      person = create(:person, organisation: person_org, name: 'Doris Dienstleister')
      I18n.with_locale(:de) { render_person({ 'type' => 'person', 'area' => 'people', 'id' => person.id, 'name' => person.name }) }

      link = page.find('li a')
      expect(link[:href]).to eq(people_path(person_id: person.id))
      expect(link[:'data-turbo-frame']).to eq('_top')
      expect(link.text).to eq('Person: Doris Dienstleister')
      expect(page).to have_css('li .bi-person')
    end

    it 'links a member by the account' do
      user_id = SecureRandom.uuid
      render_person({ 'type' => 'person', 'area' => 'people', 'id' => user_id, 'member_id' => user_id, 'name' => 'Carl Kollege' })

      expect(page.find('li a')[:href]).to eq(people_path(member_id: user_id))
    end

    it 'keeps the name of a deleted contact, without a link' do
      person = create(:person, organisation: person_org, name: 'Doris Dienstleister')
      cite = { 'type' => 'person', 'area' => 'people', 'id' => person.id, 'name' => person.name }
      person.destroy!
      render_person(cite)

      expect(page).to have_no_css('li a')
      expect(page).to have_text('Doris Dienstleister')
      expect(page).to have_css('[data-testid="citation-gone"]')
    end

    # Both languages read "Person: ...", so a rendered check cannot tell a missing English
    # key from a present one (i18n.rb falls back to German). Asked without the fallback.
    it 'has the label in both languages' do
      %i[de en].each do |locale|
        label = I18n.t('views.organisations.chats.citations.person', locale: locale, fallback: false, name: 'Doris')
        expect(label).to eq('Person: Doris'), "#{locale}: #{label}"
      end
    end
  end

  describe 'one <li> per citation (count contract)' do
    # Catches a mutation that duplicates iteration (`flat_map { |c| [c, c] }`)
    # or drops items via filter/conditional.
    it 'emits exactly N list items for N citations' do
      render_with([vision_cite, capability_cite, symbol_cite])
      expect(page).to have_css('ul li', count: 3)
    end

    it 'emits exactly 1 list item for 1 citation' do
      render_with([vision_cite])
      expect(page).to have_css('ul li', count: 1)
    end

    it 'emits exactly 5 list items for 5 citations (no silent cap)' do
      render_with(Array.new(5) { |i| capability_cite(name: "Cap#{i}", id: "c#{i}") })
      expect(page).to have_css('ul li', count: 5)
    end
  end

  describe 'collapsed by default (the point of the change)' do
    it 'renders a <details> that is NOT open — sources hidden until the user clicks' do
      render_with([vision_cite])
      expect(page).to have_css('details:not([open])')
    end

    it 'shows the citation count in the summary' do
      render_with([vision_cite, capability_cite, symbol_cite])
      expect(page.find('summary').text).to include('(3)')
    end
  end

  describe 'accessibility — icons are decorative' do
    # Bug class: removing aria-hidden lets screenreaders announce the icon's
    # private-use unicode glyph as garbage.
    it 'marks every citation icon with aria-hidden="true"' do
      render_with([vision_cite, capability_cite, symbol_cite])
      # Scope to the list rows — the collapsible <summary> has its own decorative
      # chevron icon (also aria-hidden) that we don't want to count here.
      icon_count = page.all('li span[aria-hidden="true"]').size
      expect(icon_count).to eq(3) # one decorative icon per citation
    end
  end

  describe 'symbol citation — line-number boundaries' do
    it 'renders start_line == 0 correctly (zero boundary)' do
      render_with([symbol_cite(path: 'x.rb', start_line: 0)])
      expect(rendered_content).to include('x.rb:0')
    end

    it 'renders large line numbers without truncation' do
      render_with([symbol_cite(path: 'x.rb', start_line: 99_999)])
      expect(rendered_content).to include('x.rb:99999')
    end
  end

  describe 'header appears exactly once' do
    # Mutation: putting the header inside the citations loop would emit it
    # once per citation. Test enforces single-emission.
    it 'emits the header exactly once even with many citations' do
      render_with([vision_cite, capability_cite, symbol_cite])
      header = I18n.t('views.organisations.chats.citations.header')
      expect(rendered_content.scan(header).size).to eq(1)
    end
  end

  describe 'symbol citation with integer-ish strings (JSONB read quirk)' do
    # PG JSONB stores numbers as JSON numbers and Rails round-trips them back
    # as Integer. But if someone hand-crafts citations or migrates old data,
    # start_line could come through as a string. Must not crash.
    it 'tolerates string start_line gracefully' do
      render_with([symbol_cite(start_line: '42')])
      expect(rendered_content).to include('app/foo.rb:42')
    end

    it 'tolerates nil start_line gracefully (still renders symbol label)' do
      render_with([symbol_cite(start_line: nil)])
      expect(rendered_content).to include('Foo#bar')
    end
  end

  describe 'content citations — labels + clickable links (Plan §8)' do
    let(:organisation) { create(:organisation) }
    let(:project)      { create(:project, organisation: organisation) }

    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    # REAL records behind the defaults since Feinschliff B: a citation whose target
    # no longer exists deliberately renders as text instead of a link, so the
    # invented ids these helpers used to carry would have turned every example in
    # this block into an assertion about the deleted-source path. Lazy `let`, so an
    # example only pays for the record it actually cites.
    let(:author) { create(:user) }
    let(:ticket_record) { create(:ticket, project: project, organisation: organisation) }
    let(:note_record) { create(:note, project: project, organisation: organisation, creator: author) }
    let(:document_record) { create(:document, project: project, organisation: organisation, creator: author) }
    let(:meeting_record) { create(:meeting, project: project, organisation: organisation, creator: author) }
    let(:documentation_record) do
      set = create(:documentation_set, project: project, organisation: organisation)
      create(:documentation_page, documentation_set: set, organisation: organisation)
    end

    def ticket_cite(id: ticket_record.id, number: 42, title: 'Login bug')
      { 'type' => 'ticket', 'area' => 'tickets', 'id' => id, 'project_id' => project.id,
        'number' => number, 'title' => title }
    end

    def note_cite(id: note_record.id, title: 'Kickoff')
      { 'type' => 'note', 'area' => 'notes', 'id' => id, 'project_id' => project.id, 'title' => title }
    end

    def document_cite(id: document_record.id, title: 'Spec v3')
      { 'type' => 'document', 'area' => 'documents', 'id' => id, 'project_id' => project.id, 'title' => title }
    end

    def post_cite(ticket_id: ticket_record.id, ticket_number: 7, id: SecureRandom.uuid)
      { 'type' => 'post', 'area' => 'tickets', 'id' => id, 'project_id' => project.id,
        'ticket_id' => ticket_id, 'ticket_number' => ticket_number }
    end

    def documentation_cite(id: documentation_record.id, set_id: documentation_record.documentation_set_id,
                           page: 'guide/intro.md', title: 'Intro')
      { 'type' => 'documentation', 'area' => 'documentation', 'id' => id, 'project_id' => project.id,
        'set_id' => set_id, 'page' => page, 'title' => title }
    end

    def meeting_cite(id: meeting_record.id, title: 'Kickoff-Call')
      { 'type' => 'meeting', 'area' => 'meetings', 'id' => id, 'project_id' => project.id, 'title' => title }
    end

    def meeting_analysis_cite(id: 'maid', meeting_id: meeting_record.id, title: 'Entscheidungs-Protokoll')
      { 'type' => 'meeting_analysis', 'area' => 'meetings', 'id' => id, 'project_id' => project.id,
        'meeting_id' => meeting_id, 'title' => title }
    end

    def time_report_cite(filters: {})
      { 'type' => 'time_report', 'area' => 'time_sessions', 'id' => project.id, 'project_id' => project.id,
        'title' => 'Website-Relaunch', 'filters' => filters }
    end

    def render_linked(citation)
      render_inline(described_class.new(citations: [citation], organisation: organisation, project: project))
    end

    # S3a T3: an org thread hands the component NO project, yet every content
    # citation carries its project_id — the link must come from the citation,
    # or every source chip under an org-wide answer is dead.
    it 'links a citation from its own project_id when the component has no project (org thread)' do
      render_inline(described_class.new(citations: [ticket_cite], organisation: organisation, project: nil))

      expect(page).to have_css("a[href*='/projects/#{project.id}/tickets/#{ticket_record.id}']")
    end

    it 'links a time report to ITS project, not the component one' do
      other = create(:project, organisation: organisation)
      cite = time_report_cite.merge('project_id' => other.id, 'id' => other.id)
      render_inline(described_class.new(citations: [cite], organisation: organisation, project: project))

      expect(page).to have_css("a[href*='project_id_filter=#{other.id}']")
    end

    # Regression (Prod 2026-07-30 — user saw Turbo's "Content missing" on every source
    # click): this list renders inside <turbo-frame id="chat-show">, so a link WITHOUT the
    # _top escape makes Turbo load the target page into that frame, find no matching frame
    # in the response, and render its own error instead of navigating. The bug is invisible
    # in the rendered markup except for this attribute — hence an explicit assertion, and
    # one per linked type so a future citation type cannot reintroduce it silently.
    it 'breaks EVERY content link out of the chat turbo-frame (data-turbo-frame=_top)' do
      # ONE render with all of them, not one render each (Feinschliff B): every render
      # builds its own existence resolver, and a loop of them is an N+1 that
      # Prosopite rightly stops. An answer with many sources is also the shape
      # production has. The comment hangs on a SECOND ticket and the analysis on a
      # SECOND meeting on purpose: each would otherwise group with its parent (that
      # is the point of the grouping) and this example would lose a type.
      other_ticket = create(:ticket, project: project, organisation: organisation)
      other_meeting = create(:meeting, project: project, organisation: organisation, creator: author)
      # help_page (product knowledge S2): its link needs no project, and this escape is the very
      # reason get_help_page keeps /hilfe links out of the answer text.
      help_cite = { 'type' => 'help_page', 'source' => 'help', 'id' => 'guides/features/time-tracking',
                    'title' => 'Zeiterfassung' }
      cites = [ticket_cite, note_cite, document_cite, post_cite(ticket_id: other_ticket.id),
               documentation_cite, meeting_cite, meeting_analysis_cite(meeting_id: other_meeting.id),
               time_report_cite, help_cite]

      render_inline(described_class.new(citations: cites, organisation: organisation, project: project))
      anchors = page.all('a')

      expect(anchors.size).to eq(cites.size), 'a citation type rendered no link at all'
      anchors.each do |anchor|
        expect(anchor[:'data-turbo-frame']).to eq('_top'), 'a citation links without the _top escape'
      end
    end

    # S2: a report citation has no record; it reopens the project's time list under the
    # SAME filters the numbers were computed with, so the chip shows the number's source.
    it 'renders a time_report label, links to the filtered project time list, shows the stopwatch' do
      render_linked(time_report_cite(filters: { 'start_date' => '2026-08-01', 'end_date' => '2026-08-31',
                                                'creator_id' => 'the-creator',
                                                'ticket_id' => 'the-ticket', 'title' => 'not a param' }))
      expect(rendered_content).to include('Website-Relaunch')
      expect(page).to have_css('a[href*="/time-tracking?"]')
      expect(page).to have_css('a[href*="start_date=2026-08-01"]')
      expect(page).to have_css('a[href*="end_date=2026-08-31"]')
      expect(page).to have_css('a[href*="creator_id=the-creator"]')
      expect(page).to have_css('a[href*="ticket_id=the-ticket"]')
      expect(page).not_to have_css('a[href*="title="]')
      expect(page).to have_css('.bi-stopwatch')
    end

    # Zweitreview F1: the index has its own defaults (current month, billed hidden).
    # A link that stands for a reported NUMBER must neutralise them, or the list
    # shows a different set than the chat answer promised. Params come from the
    # shared owner TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS; the values are
    # asserted literally here so a silent change of the constant breaks this pin.
    it 'neutralises the index defaults on every time_report link (all buckets, all dates, sum on)' do
      render_linked(time_report_cite(filters: { 'start_date' => '2026-08-01' }))
      href = page.find('a')[:href]
      %w[billed in_billing without_billing].each do |bucket|
        expect(href).to include("status_filters%5B%5D=#{bucket}")
      end
      expect(href).to include('date_range=all')
      expect(href).to include('start_date=2026-08-01')
    end

    it 'links a time_report with malformed filters to the neutralised time list instead of crashing' do
      render_linked(time_report_cite(filters: 'garbage'))
      expect(page).to have_css('a[href*="/time-tracking?"]')
      expect(page).to have_css('a[href*="date_range=all"]')
      expect(page).not_to have_css('a[href*="start_date"]')
    end

    it 'renders a ticket label (number + title), links to the ticket, shows its icon' do
      render_linked(ticket_cite(number: 42, title: 'Login bug'))
      expect(rendered_content).to include('Login bug')
      expect(page).to have_css(%(a[href*="/tickets/#{ticket_record.id}"]))
      expect(page).to have_css('.bi-card-checklist')
    end

    it 'renders a note citation and links to the note' do
      render_linked(note_cite(title: 'Kickoff'))
      expect(rendered_content).to include('Kickoff')
      expect(page).to have_css(%(a[href*="/notes/#{note_record.id}"]))
    end

    it 'renders a document citation and links to the document' do
      render_linked(document_cite(title: 'Spec v3'))
      expect(rendered_content).to include('Spec v3')
      expect(page).to have_css(%(a[href*="/documents/#{document_record.id}"]))
    end

    it 'links a post citation to its TICKET (a comment has no own page)' do
      render_linked(post_cite(ticket_number: 7))
      expect(page).to have_css(%(a[href*="/tickets/#{ticket_record.id}"]))
      expect(rendered_content).to include('7')
    end

    it 'renders a documentation citation and links to the browsing route (set + page path)' do
      render_linked(documentation_cite(page: 'guide/intro.md', title: 'Intro'))
      expect(rendered_content).to include('Intro')
      expect(page).to have_css('a[href*="/documentation"]')
      expect(page).to have_css(%(a[href*="set_id=#{documentation_record.documentation_set_id}"]))
      expect(page).to have_css('.bi-book')
    end

    it 'renders a documentation citation as plain text (no link) when set_id/page are blank' do
      render_linked(documentation_cite(set_id: '', page: ''))
      expect(rendered_content).to include('Intro')
      expect(page).not_to have_css('a')
    end

    it 'renders a meeting citation, links to the meeting, shows its icon (Gespräche Slice 6)' do
      render_linked(meeting_cite(title: 'Kickoff-Call'))
      expect(rendered_content).to include('Kickoff-Call')
      expect(page).to have_css(%(a[href*="/meetings/#{meeting_record.id}"]))
      expect(page).to have_css('.bi-chat-quote')
    end

    it 'renders a meeting_analysis citation, links to its MEETING (via meeting_id), shows the magic icon (Slice 7b)' do
      # An analysis has no own page — the link deep-links to the meeting via meeting_id,
      # NOT the analysis id. Label is the prompt title (frozen snapshot).
      render_linked(meeting_analysis_cite(id: 'the-analysis', title: 'Entscheidungs-Protokoll'))
      expect(rendered_content).to include('Entscheidungs-Protokoll')
      expect(page).to have_css(%(a[href*="/meetings/#{meeting_record.id}"]))
      expect(page).not_to have_css('a[href*="the-analysis"]')
      expect(page).to have_css('.bi-magic')
    end

    it 'escapes HTML in a ticket title (XSS safety)' do
      render_linked(ticket_cite(title: '<script>alert(1)</script>'))
      expect(rendered_content).not_to include('<script>alert(1)</script>')
    end

    it 'renders content as PLAIN TEXT (no link) when org/project are absent (broadcast w/o Current.*)' do
      render_inline(described_class.new(citations: [ticket_cite(title: 'Login bug')]))
      expect(rendered_content).to include('Login bug')
      expect(page).not_to have_css('a')
    end
  end

  # Feinschliff B (P8 + P5): one row per SOURCE, and a source whose object is gone
  # keeps its label but loses its link.
  describe 'grouping by source and deleted targets' do
    let(:organisation) { create(:organisation) }
    let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:author) { create(:user) }

    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    def ticket_cite(ticket, number: 7)
      { 'type' => 'ticket', 'area' => 'tickets', 'id' => ticket.id, 'project_id' => project.id,
        'number' => number, 'title' => 'Login bug' }
    end

    def post_cite(ticket, number: 7)
      { 'type' => 'post', 'area' => 'tickets', 'id' => SecureRandom.uuid, 'project_id' => project.id,
        'ticket_id' => ticket.id, 'ticket_number' => number }
    end

    def render_list(citations)
      render_inline(described_class.new(citations: citations, organisation: organisation, project: project))
    end

    it 'collapses a ticket and its comments into ONE row that counts the passages' do
      ticket = create(:ticket, project: project, organisation: organisation)
      render_list([ticket_cite(ticket), post_cite(ticket), post_cite(ticket)])

      expect(page).to have_css('[data-testid="citation-row"]', count: 1)
      # The TICKET speaks for the group: it carries number and title, a comment carries
      # neither.
      expect(rendered_content).to include('Login bug')
      expect(page.find('[data-testid="citation-hits"]')).to have_text('3')
      expect(page).to have_css(%(a[href*="/tickets/#{ticket.id}"]), count: 1)
    end

    it 'keeps two DIFFERENT tickets apart' do
      first = create(:ticket, project: project, organisation: organisation)
      second = create(:ticket, project: project, organisation: organisation)
      render_list([ticket_cite(first), ticket_cite(second, number: 8)])

      expect(page).to have_css('[data-testid="citation-row"]', count: 2)
      expect(page).to have_no_css('[data-testid="citation-hits"]')
    end

    it 'counts ROWS in the summary, not raw citations' do
      ticket = create(:ticket, project: project, organisation: organisation)
      render_list([ticket_cite(ticket), post_cite(ticket), post_cite(ticket)])

      expect(page.find('summary')).to have_text('(1)')
    end

    it 'groups comments without their ticket into one row pointing at that ticket' do
      ticket = create(:ticket, project: project, organisation: organisation)
      render_list([post_cite(ticket), post_cite(ticket), post_cite(ticket)])

      expect(page).to have_css('[data-testid="citation-row"]', count: 1)
      expect(page.find('[data-testid="citation-hits"]')).to have_text('3')
      expect(page).to have_css(%(a[href*="/tickets/#{ticket.id}"]))
    end

    # The rank decides, not the order. jsonb does not preserve key order and the
    # producers append tool citations, so "the first one wins" would be a coin toss
    # that the poorer hash can win.
    it 'lets the MEETING speak for its analysis even when the analysis comes first' do
      meeting = create(:meeting, project: project, organisation: organisation, creator: author)
      analysis = { 'type' => 'meeting_analysis', 'area' => 'meetings', 'id' => SecureRandom.uuid,
                   'project_id' => project.id, 'meeting_id' => meeting.id, 'title' => 'Analyse-Titel' }
      meeting_cite = { 'type' => 'meeting', 'area' => 'meetings', 'id' => meeting.id,
                       'project_id' => project.id, 'title' => 'Kickoff-Call' }

      render_list([analysis, meeting_cite])

      expect(page).to have_css('[data-testid="citation-row"]', count: 1)
      expect(rendered_content).to include('Kickoff-Call')
      expect(rendered_content).not_to include('Analyse-Titel')
    end

    # A report addresses a SLICE of its project, not the project. Two of them share a
    # target and are still two sources: two numbers, two filter sets, two links. This
    # is the render-side half of the bug the producer already fixed once
    # (Citations#time_report_id, Viertreview F5) -- grouping on the bare target brought
    # it back, with the second number losing its checkable source.
    it 'keeps two REPORTS over the same project apart' do
      july = Lalabase::Citations.time_report(project, 'start_date' => '2026-07-01',
                                                      'end_date' => '2026-07-31').deep_stringify_keys
      august = Lalabase::Citations.time_report(project, 'start_date' => '2026-08-01',
                                                        'end_date' => '2026-08-31').deep_stringify_keys

      render_list([july, august])

      expect(page).to have_css('[data-testid="citation-row"]', count: 2)
      # Two DIFFERENT lists, not the same one twice: the second row must not inherit
      # the first report's filters.
      hrefs = page.all('a').map { |anchor| anchor[:href] }
      expect(hrefs.uniq.size).to eq(2)
      expect(hrefs.join).to include('2026-08-01')
      # And nothing claims these are two passages of one source.
      expect(page).to have_no_css('[data-testid="citation-hits"]')
    end

    it 'keeps two code citations apart even though neither points at a record' do
      render_list([{ 'type' => 'vision', 'id' => 'v-1' },
                   { 'type' => 'capability', 'id' => 'c-1', 'name' => 'Notifications' }])

      expect(page).to have_css('[data-testid="citation-row"]', count: 2)
    end

    describe 'a target that no longer exists' do
      it 'keeps the label, drops the link and says so' do
        ticket = create(:ticket, project: project, organisation: organisation)
        cite = ticket_cite(ticket)

        # Flow anchor: the very same citation links while the ticket is there.
        render_list([cite])
        expect(page).to have_css('a')

        ticket.destroy!
        render_list([cite])

        expect(rendered_content).to include('Login bug')
        expect(page).to have_no_css('a')
        expect(page.find('[data-testid="citation-gone"]'))
          .to have_text(I18n.t('views.organisations.chats.citations.gone'))
      end

      it 'drops the link of a comment whose ticket is gone' do
        ticket = create(:ticket, project: project, organisation: organisation)
        cite = post_cite(ticket)
        ticket.destroy!

        render_list([cite])

        expect(page).to have_no_css('a')
        expect(page).to have_css('[data-testid="citation-gone"]')
      end

      it 'says nothing about a deleted target when there is no organisation to ask' do
        ticket = create(:ticket, project: project, organisation: organisation)
        cite = ticket_cite(ticket)
        ticket.destroy!

        render_inline(described_class.new(citations: [cite], organisation: nil, project: project))

        # No organisation means no link either (that was already true), but the row
        # must not CLAIM the source is deleted on evidence it never gathered.
        expect(page).to have_no_css('[data-testid="citation-gone"]')
      end
    end
  end

  # R3 (2026-08-31): the rows carry the same [n] the prose resolves. The numbering
  # is handed in built over the FULL persisted list (MessageComponent), because
  # this component only sees the viewer's filtered subset and a subset numbering
  # would shift per viewer and disagree with the [n] in the text.
  describe 'the [n] numbers on the rows' do
    def numbered_ticket(id:, number: 42)
      { 'type' => 'ticket', 'area' => 'tickets', 'id' => id, 'number' => number, 'title' => 'T' }
    end

    def numbered_post(id:, ticket_id:, number: 42)
      { 'type' => 'post', 'area' => 'tickets', 'id' => id, 'ticket_id' => ticket_id,
        'ticket_number' => number }
    end

    def render_numbered(visible, full)
      render_inline(described_class.new(citations: visible,
                                        numbering: Lalabase::ProjectRag::SourceNumbering.for(full)))
    end

    it 'labels a row with its position in the FULL list, not in the filtered subset' do
      full = [vision_cite, capability_cite, symbol_cite]
      render_numbered([symbol_cite], full)

      expect(page).to have_css('[data-testid="citation-numbers"]', text: '[3]', count: 1)
    end

    it 'gives a grouped row every member number, the lead first' do
      # Full-list order puts a comment BEFORE its ticket, so lead-first is
      # distinguishable from ascending: the ticket (lead) is [2].
      post = numbered_post(id: 'p1', ticket_id: 't1')
      ticket = numbered_ticket(id: 't1')
      render_numbered([post, ticket], [post, ticket])

      expect(page).to have_css('[data-testid="citation-row"]', count: 1)
      expect(page.find('[data-testid="citation-numbers"]')).to have_text('[2] [1]')
    end

    it 'renders no numbers without a numbering (old callers unchanged)' do
      render_with([vision_cite])

      expect(page).to have_no_css('[data-testid="citation-numbers"]')
    end
  end
end
