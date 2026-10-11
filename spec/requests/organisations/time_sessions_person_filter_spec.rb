# frozen_string_literal: true

require 'rails_helper'

# What: The person filter of the time list, offered under "+ Filter" (step 1 of
#       doc/zeiten_weitere_filter_plan.md, decisions D1-D5).
# Type: Request spec. The menu is a <details> inside a <details>, which needs no
#       JavaScript, so everything asserted here is decided in Ruby.
# Why:  The parameter (creator_id) existed, but only the reader's own id could be
#       chosen ("Nur meine Zeiten"). The menu now names people, and a name on
#       this page is a disclosure: it may only ever be someone whose time the
#       reader can already see in the list (D2, D5). That half is the :ci_guard.
RSpec.describe 'Time list: the person filter', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:member_role)  { create(:role, organisation: organisation) }

  let(:viewer) { create(:user, first_name: 'Vera', last_name: 'Viewer') }
  let(:anna)   { create(:user, first_name: 'Anna', last_name: 'Aufwand') }
  let(:ben)    { create(:user, first_name: 'Ben', last_name: 'Verborgen') }

  let(:project_a) { with_tenant { create(:project, organisation: organisation, name: 'Sichtbar') } }
  let(:project_b) { with_tenant { create(:project, organisation: organisation, name: 'Geschlossen') } }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause
    with_tenant do
      [viewer, anna, ben].each do |user|
        create(:membership, user: user, organisation: organisation, role: member_role, active: true)
      end
    end
    book(project_a, viewer, 'Zeile der Leserin')
    book(project_a, anna, 'Zeile von Anna')
    # Ben books only where the viewer sees nothing.
    book(project_b, ben, 'Zeile von Ben')
    sign_in viewer
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def book(project, creator, description)
    with_tenant do
      create(:time_session, organisation: organisation, project: project, creator: creator,
                            duration: 60, occurred_on: Date.current, description: description)
    end
  end

  def grant(project, **flags)
    with_tenant { create(:time_session_permission, user: viewer, project: project, **flags) }
  end

  def get_list(**params)
    get organisation_time_sessions_path(organisation, date_range: 'all', **params)
    expect(response).to have_http_status(:ok)
  end

  def doc = Nokogiri::HTML(response.body)

  # The filter panel itself: proven present before anything is claimed absent
  # from it, or a negative assertion is green on a page without a panel.
  def panel
    node = doc.at_css('[data-filter-pill="period"]')
    expect(node).to be_present
    node
  end

  def add_menu = doc.at_css('[data-filter-add="add"]')
  def add_section(kind) = add_menu&.at_css(%([data-filter-add-section="#{kind}"]))
  def person_pill = doc.at_css('[data-filter-pill="person"]')

  def option_names(scope)
    scope.css('a[data-filter-pill-option]').map { |link| link.text.squish }
  end

  def query_of(link) = Rack::Utils.parse_nested_query(URI.parse(link['href']).query)

  context 'when the reader sees everyone in one project' do
    before { grant(project_a, can_view_own: true, can_view_all: true) }

    it 'offers the people whose time the reader can see, and nobody else' do
      get_list
      panel

      section = add_section('person')
      expect(section).to be_present
      names = option_names(section)
      # By name, not by who booked last: a menu of people is looked up, not scanned.
      expect(names).to eq(['Anna Aufwand', 'Vera Viewer'])
      expect(response.body).not_to include('Verborgen')
    end

    it 'narrows the list to the chosen person, who then has a pill of their own' do
      get_list
      link = add_section('person').css('a[data-filter-pill-option]').find { |a| a.text.include?('Anna') }
      expect(query_of(link)).to include('creator_id' => anna.id)

      get_list(creator_id: anna.id)

      expect(response.body).to include('Zeile von Anna')
      expect(response.body).not_to include('Zeile der Leserin')
      expect(person_pill['data-filter-pill-state']).to eq('set')
      expect(person_pill.at_css('summary').text.squish).to include('Anna Aufwand')

      clear = person_pill.at_css('summary a[data-query-toggle-owns]')
      expect(query_of(clear)).not_to have_key('creator_id')
      expect(JSON.parse(clear['data-query-toggle-owns'])).to include(['creator_id', ''])
    end

    # Without the field a long team is a list to scroll, not to search.
    it 'lets the person list be narrowed by typing, like the pill menus' do
      get_list

      field = add_section('person').at_css('input[data-filter-menu-search-target="query"]')
      expect(field).to be_present
      expect(field.ancestors('[data-controller~="filter-menu-search"]')).to be_present
    end

    # A choice adds a filter, it does not replace the others.
    it 'keeps the filters already set when a person is chosen' do
      get_list(project_id_filter: project_a.id, search: 'Zeile')

      link = add_section('person').css('a[data-filter-pill-option]').find { |a| a.text.include?('Anna') }
      expect(query_of(link)).to include('creator_id' => anna.id, 'project_id_filter' => project_a.id,
                                        'search' => 'Zeile', 'date_range' => 'all')
    end

    it 'marks the chosen person in the pill menu and offers the way back to everyone' do
      get_list(creator_id: anna.id)

      links = person_pill.css('a[data-filter-pill-option]')
      chosen = links.select { |link| link['aria-current'] == 'true' }
      expect(chosen.map { |link| link.text.squish }).to eq(['Anna Aufwand'])

      everyone = links.first
      expect(everyone.text.squish).to eq(I18n.t('views.organisations.time_sessions.index.filter_all_people'))
      expect(query_of(everyone)).not_to have_key('creator_id')
    end

    # The empty state reads the same label as the pill: a filter cannot be
    # called one thing while it narrows the list and another once it emptied it.
    it 'names the person in the empty state, with a removal that brings rows back' do
      get_list(creator_id: anna.id, search: 'Zeile der Leserin')

      chip = doc.at_css('[data-empty-filter="creator"]')
      expect(chip.text.squish).to include('Person: Anna Aufwand')
      expect(query_of(chip)).not_to have_key('creator_id')
      expect(query_of(chip)).to include('search' => 'Zeile der Leserin')
    end

    # Names follow the reader's own display setting, like every other name.
    it 'spells the names the way the reader chose to see names' do
      viewer.preference_store.set!('name_display', 'first_last_initial')

      get_list(creator_id: anna.id)

      expect(person_pill.at_css('summary').text.squish).to include('Anna A.')
      expect(person_pill.at_css('summary').text).not_to include('Aufwand')
    end

    # D2: the menu is built from bookings, not from memberships. Someone who
    # left keeps their name on the time they booked.
    it 'still offers a colleague whose membership was switched off' do
      with_tenant { Membership.find_by!(user: anna, organisation: organisation).update!(active: false) }

      get_list

      expect(option_names(add_section('person'))).to include('Anna Aufwand')
    end

    it 'does not offer the person a second time while one is chosen' do
      get_list(creator_id: anna.id)

      expect(person_pill).to be_present
      expect(add_section('person')).to be_nil
    end

    it 'keeps the own id on the switch "Nur meine Zeiten", without a person pill' do
      get_list(creator_id: viewer.id)
      panel

      expect(person_pill).to be_nil
      expect(response.body).to include('Zeile der Leserin')
    end

    # D5: a typed id outside the list is never resolved to a name. The page
    # answers as it did before this filter existed.
    it 'names nobody for an id the reader cannot see' do
      get_list(creator_id: ben.id)
      panel

      expect(person_pill).to be_nil
      expect(response.body).not_to include('Verborgen')
      expect(doc.at_css('[data-empty-filter="creator"]')&.text&.squish)
        .to include(I18n.t('views.organisations.time_sessions.empty_reason.creator_other'))
    end

    # A uuid is the same id in either case: Postgres filters the list by it
    # either way, so the page has to recognise it either way too, or the list
    # narrows to Anna under a line that says nothing about her (review, 29.09.2026).
    it 'recognises a person whose id arrives in capitals' do
      get_list(creator_id: anna.id.upcase)

      expect(response.body).to include('Zeile von Anna')
      expect(person_pill.at_css('summary').text.squish).to include('Anna Aufwand')
      expect(person_pill.css('a[aria-current="true"]').map { |link| link.text.squish }).to eq(['Anna Aufwand'])
      expect(add_section('person')).to be_nil
    end

    # The two spellings from the second review. Whatever the list does with an
    # id, the pill says the same: Anna's rows under Anna's name, or no rows and
    # no name.
    it 'recognises an id without hyphens, as the list does' do
      get_list(creator_id: anna.id.delete('-'))

      expect(response.body).to include('Zeile von Anna')
      expect(person_pill.at_css('summary').text.squish).to include('Anna Aufwand')
    end

    # The empty state speaks in the same state as the switch: a capitalised own
    # id empties nothing it would not empty in lower case, and the chip offered
    # for removal is still "Nur meine Zeiten", not a stranger's.
    it 'calls a capitalised own id "Nur meine Zeiten" in the empty state' do
      get_list(creator_id: viewer.id.upcase, search: 'Zeile von Anna')

      chip = doc.at_css('[data-empty-filter="creator"]')
      expect(chip.text.squish).to include(I18n.t('views.organisations.time_sessions.empty_reason.names.creator'))
      expect(chip.text).not_to include(I18n.t('views.organisations.time_sessions.empty_reason.creator_other'))
    end

    # A chosen person narrows the list, so it counts on the mobile badge and
    # makes the reset worth offering, like every other filter.
    it 'counts on the badge and brings the reset' do
      neutral = { status_filters: TimeSession::BILLING_STATUS_FILTERS }

      get_list(**neutral)
      without = doc.at_css('[data-filter-count]')['data-filter-count'].to_i
      expect(doc.at_css('#time_filter_reset a[data-filter-reset]')).to be_nil

      get_list(**neutral, creator_id: anna.id)
      expect(doc.at_css('[data-filter-count]')['data-filter-count'].to_i).to eq(without + 1)
      expect(doc.at_css('#time_filter_reset a[data-filter-reset]')).to be_present
    end

    it 'names nobody for an id wrapped in blanks, which the list does not match either' do
      get_list(creator_id: " #{anna.id} ")
      panel

      expect(response.body).not_to include('Zeile von Anna')
      expect(person_pill).to be_nil
    end

    it 'recognises the reader\'s own id in capitals as the switch' do
      get_list(creator_id: viewer.id.upcase)
      panel

      expect(person_pill).to be_nil
      expect(doc.at_css('[data-status-box="creator_mine"]')['aria-current']).to eq('true')
    end

    # A deleted booking is no booking: the list does not show it, so it must not
    # put its author's name on the page either.
    it 'names nobody whose only booking was deleted' do
      dora = create(:user, first_name: 'Dora', last_name: 'Geloescht')
      with_tenant do
        create(:membership, user: dora, organisation: organisation, role: member_role, active: true)
      end
      book(project_a, dora, 'Geloeschte Zeile').update_column(:deleted_at, Time.current)

      get_list
      expect(option_names(add_section('person'))).not_to include('Dora Geloescht')

      get_list(creator_id: dora.id)
      panel
      expect(person_pill).to be_nil
      expect(response.body).not_to include('Geloescht')
    end

    it 'answers a junk id without a name and without an error' do
      get_list(creator_id: 'not-a-uuid')
      panel

      expect(person_pill).to be_nil
    end

    it 'carries the chosen person across a submit of the filter form' do
      get_list(creator_id: anna.id)

      field = doc.at_css('input[type="hidden"][data-filter-state="creator_id"]')
      expect(field['value']).to eq(anna.id)
    end
  end

  # The tenant boundary. For an ADMIN reader the viewing scope passes every
  # row through (TimeSessions::ViewingScope, `return relation if @admin`), so
  # the organisation condition on the base query is the only thing between the
  # menu and another organisation's people. A member reader would not show a
  # leak here: their scope is narrowed to their own projects anyway.
  context 'when another organisation has bookings of its own' do
    let(:foreign_org) { create(:organisation) }
    let(:stranger)    { create(:user, first_name: 'Xaver', last_name: 'Fremdfirma') }

    before do
      with_tenant do
        admin_role = create(:admin_role, organisation: organisation)
        Membership.find_by!(user: viewer, organisation: organisation).update!(role: admin_role)
      end
      ActsAsTenant.with_tenant(foreign_org) do
        foreign_role = create(:role, organisation: foreign_org)
        create(:membership, user: stranger, organisation: foreign_org, role: foreign_role, active: true)
        foreign_project = create(:project, organisation: foreign_org)
        create(:time_session, organisation: foreign_org, project: foreign_project, creator: stranger,
                              duration: 60, occurred_on: Date.current, description: 'Fremde Firma')
      end
    end

    it 'never offers or names a person from it' do
      get_list
      expect(option_names(add_section('person'))).to eq(['Anna Aufwand', 'Ben Verborgen', 'Vera Viewer'])

      get_list(creator_id: stranger.id)
      panel
      expect(person_pill).to be_nil
      expect(response.body).not_to include('Fremdfirma', 'Fremde Firma')
    end
  end

  # The other side of the isolation: the rule is the viewing scope, not "only
  # the projects I booked in". A second project with full sight brings its
  # people in.
  context 'when the reader sees everyone in both projects' do
    before do
      grant(project_a, can_view_own: true, can_view_all: true)
      grant(project_b, can_view_own: true, can_view_all: true)
    end

    it 'offers the people of both, and names one from either' do
      get_list

      expect(option_names(add_section('person'))).to eq(['Anna Aufwand', 'Ben Verborgen', 'Vera Viewer'])

      get_list(creator_id: ben.id)
      expect(person_pill.at_css('summary').text.squish).to include('Ben Verborgen')
    end
  end

  # D3 excludes the reader, not "one person": a reader who sees only Ben's time
  # and has none of their own still has someone to choose (review, 29.09.2026).
  context 'when the only person the reader can see is a colleague' do
    before { grant(project_b, can_view_own: true, can_view_all: true) }

    it 'offers that colleague' do
      get_list
      panel

      expect(option_names(add_section('person'))).to eq(['Ben Verborgen'])
    end
  end

  # D3: one name in the menu is the reader's own, which the switch already
  # offers. With nothing else to add, there is no "+ Filter" at all.
  context 'when the reader sees only their own time' do
    before do
      grant(project_a, can_view_own: true, can_view_all: false)
      grant(project_b, can_view_own: true, can_view_all: false)
    end

    it 'offers no "+ Filter"' do
      get_list
      panel

      expect(add_menu).to be_nil
      expect(response.body).not_to include('Anna Aufwand', 'Verborgen')
    end
  end
end
