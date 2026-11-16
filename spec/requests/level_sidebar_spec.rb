# frozen_string_literal: true

require 'rails_helper'

# What: the sidebar of the level above the organisations (Belegungstabelle F48, navigation
#       plan PR 1): the same rows on the cockpit ("Übersicht") and on the inbox above the
#       organisations ("Gesamt-Inbox"), every organisation with an active membership as a
#       way INTO it, with its unread count.
# Why:  the pages run without a tenant and list organisations across tenants. What the
#       sidebar must not show (an organisation the person left) and what it must not do
#       (narrow a list, mark an organisation) is pinned here; the select field at the list
#       is the only filter.
RSpec.describe 'The sidebar of the level above the organisations', :ci_guard, :real_transactions, type: :request do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }

  def project_in(org)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org) }
  end

  def unread_row(org, project, title)
    ActsAsTenant.with_tenant(org) do
      ticket = create(:ticket, project: project, title: title)
      create(:notification, recipient: user, organisation: org, project: project, notifiable: ticket,
                            event_type: 'ticket_commented', channel: 'in_app', state: :delivered)
    end
  end

  let(:north_project) { project_in(north) }
  let(:south_project) { project_in(south) }

  # North with two unread rows, south with one.
  let!(:rows) do
    Prosopite.pause do
      make_token_owner_a_member(user, north, projects: [north_project])
      make_token_owner_a_member(user, south, projects: [south_project])
      [unread_row(north, north_project, 'Regal wackelt'), unread_row(north, north_project, 'Tor klemmt'),
       unread_row(south, south_project, 'Paket fehlt')]
    end
  end

  before { sign_in user }

  after { ActsAsTenant.current_tenant = nil }

  def page_at(path)
    get path
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def nav(doc)
    doc.at_css('[data-all-inboxes-nav]').tap { |element| expect(element).to be_present }
  end

  def row_names(doc)
    nav(doc).css('a').map { |a| a.text.squish.sub(/ \d+\z/, '') }
  end

  # (name, href, count) of every organisation row, in the order shown.
  def organisation_rows(doc)
    nav(doc).css('nav a').map { |a| [a.text.squish.sub(/ \d+\z/, ''), a['href'], a.text.squish[/ (\d+)\z/, 1]] }
  end

  def link(doc, name)
    nav(doc).css('a').find { |a| a.text.squish.sub(/ \d+\z/, '') == name }
  end

  describe 'on the cockpit and on the inbox above the organisations' do
    it 'shows the same rows, the lists of the level first, then every organisation with its count' do
      cockpit = page_at(select_organisation_path)
      inbox = page_at(all_inboxes_path)

      expected = [I18n.t('navigation.overview'), I18n.t('navigation.all_inboxes'), I18n.t('navigation.people'), 'Nord GmbH', 'Sued AG']
      expect(row_names(cockpit)).to eq(expected)
      expect(row_names(inbox)).to eq(expected)
      expect(organisation_rows(cockpit)).to eq(organisation_rows(inbox))
      expect(organisation_rows(cockpit)).to eq([
                                                 ['Nord GmbH', organisation_root_path(organisation_id: north.id), '2'],
                                                 ['Sued AG', organisation_root_path(organisation_id: south.id), '1']
                                               ])
    end

    # One request per example: Prosopite reads the same lookups of a second request as N+1.
    { 'the cockpit' => -> { select_organisation_path }, 'the inbox' => -> { all_inboxes_path },
      'the narrowed inbox' => -> { all_inboxes_path(org: south.id) } }.each do |where, path|
      it "leads every organisation row into that organisation on #{where}, and no link of the sidebar narrows" do
        doc = page_at(instance_exec(&path))
        expect(organisation_rows(doc).map(&:second))
          .to eq([organisation_root_path(organisation_id: north.id), organisation_root_path(organisation_id: south.id)])
        expect(nav(doc).css('a').pluck('href')).to all(satisfy { |href| !href.include?('org=') })
      end
    end

    it 'marks "Übersicht" on the cockpit and nothing else' do
      doc = page_at(select_organisation_path)
      overview = link(doc, I18n.t('navigation.overview'))
      expect(overview['aria-current']).to eq('page')
      expect(overview['class']).to include('sidebar-row--active')
      expect(nav(doc).css('a.sidebar-row--active').size).to eq(1)
      expect(nav(doc).css('a[aria-current]').size).to eq(1)
    end

    { 'the inbox' => -> { all_inboxes_path }, 'the narrowed inbox' => -> { all_inboxes_path(org: south.id) } }.each do |where, path|
      it "marks \"Gesamt-Inbox\" on #{where} and never an organisation" do
        doc = page_at(instance_exec(&path))
        inbox = link(doc, I18n.t('navigation.all_inboxes'))
        expect(inbox['aria-current']).to eq('page')
        expect(inbox['class']).to include('sidebar-row--active')
        expect(nav(doc).css('nav a').size).to eq(2)
        nav(doc).css('nav a').each do |row|
          expect(row['aria-current']).to be_nil
          expect(row['class']).not_to include('sidebar-row--active')
        end
      end
    end

    it 'shows the counts of the tiles on the cockpit, from the read the page made' do
      expect(Notifications::UnreadSignals).not_to receive(:counts_for)
      doc = page_at(select_organisation_path)
      expect(organisation_rows(doc).map(&:last)).to eq(%w[2 1])
    end

    it 'shows the counts of the inbox on the inbox, from the read the page made' do
      expect(Notifications::UnreadSignals).not_to receive(:counts_for)
      doc = page_at(all_inboxes_path)
      expect(organisation_rows(doc).map(&:last)).to eq(%w[2 1])
    end

    it 'orders the organisations by name on the cockpit, as on the inbox' do
      Prosopite.pause { make_token_owner_a_member(user, create(:organisation, name: 'Alpen KG')) }
      expect(organisation_rows(page_at(select_organisation_path)).map(&:first)).to eq(['Alpen KG', 'Nord GmbH', 'Sued AG'])
      expect(organisation_rows(page_at(all_inboxes_path)).map(&:first)).to eq(['Alpen KG', 'Nord GmbH', 'Sued AG'])
    end
  end

  # The people above the organisations (GET /people): a list of the level like the inbox,
  # with a row of its own from two organisations on.
  describe 'on the people above the organisations' do
    { 'the people page' => -> { all_people_path }, 'the searched people page' => -> { all_people_path(q: 'niemand') } }.each do |where, path|
      it "shows the rows of the level on #{where}, marks \"Personen\" and nothing else, and no link of the sidebar narrows" do
        doc = page_at(instance_exec(&path))

        expect(row_names(doc)).to eq([I18n.t('navigation.overview'), I18n.t('navigation.all_inboxes'),
                                      I18n.t('navigation.people'), 'Nord GmbH', 'Sued AG'])
        people = link(doc, I18n.t('navigation.people'))
        expect(people['href']).to eq(all_people_path)
        expect(people['aria-current']).to eq('page')
        expect(people['class']).to include('sidebar-row--active')
        expect(nav(doc).css('a.sidebar-row--active').size).to eq(1)
        expect(nav(doc).css('a[aria-current]').size).to eq(1)
        expect(organisation_rows(doc).map(&:second))
          .to eq([organisation_root_path(organisation_id: north.id), organisation_root_path(organisation_id: south.id)])
        expect(nav(doc).css('a').pluck('href')).to all(satisfy { |href| href.exclude?('org=') && href.exclude?('q=') })
      end
    end

    { 'the cockpit' => -> { select_organisation_path }, 'the inbox' => -> { all_inboxes_path } }.each do |where, path|
      it "leads to the people page from #{where} and does not mark \"Personen\" there" do
        people = link(page_at(instance_exec(&path)), I18n.t('navigation.people'))

        expect(people['href']).to eq(all_people_path)
        expect(people['aria-current']).to be_nil
        expect(people['class']).not_to include('sidebar-row--active')
      end
    end

    # The page loads no counts of its own: the sidebar asks the reader of the switcher.
    it 'shows the unread counts of the organisations on the people page' do
      expect(organisation_rows(page_at(all_people_path)).map(&:last)).to eq(%w[2 1])
    end
  end

  describe 'the cockpit is "Übersicht"' do
    it 'names it so in its heading and in the browser title, in German' do
      doc = page_at(select_organisation_path)
      expect(doc.at_css('main h1').text.squish).to eq('Übersicht')
      # The title the page sets, in the form of the other pages that set one ("Gesamt-Inbox").
      expect(doc.at_css('title').text).to eq('Übersicht')
    end

    it 'names it so in English' do
      user.update!(language_preference: 'en')
      doc = page_at(select_organisation_path)
      expect(doc.at_css('main h1').text.squish).to eq('Overview')
      expect(doc.at_css('title').text).to include('Overview')
      expect(row_names(doc).first).to eq('Overview')
    end
  end

  describe 'for a person with one organisation' do
    before { Prosopite.pause { south.memberships.where(user: user).delete_all } }

    it 'shows "Übersicht" and the organisation, and no "Gesamt-Inbox"' do
      doc = page_at(select_organisation_path)
      expect(row_names(doc)).to eq([I18n.t('navigation.overview'), 'Nord GmbH'])
    end

    # A list above the organisations needs two of them: with one, neither row is offered.
    it 'offers no "Personen" row either' do
      doc = page_at(select_organisation_path)
      expect(row_names(doc)).not_to include(I18n.t('navigation.people'), I18n.t('navigation.all_inboxes'))
      expect(nav(doc).css('a').pluck('href')).not_to include(all_people_path)
      expect(row_names(doc)).to include('Nord GmbH')
    end
  end

  describe 'for a person without any active organisation' do
    before { Prosopite.pause { Membership.where(user: user).update_all(active: false) } }

    it 'shows "Übersicht" and no empty label of the organisations' do
      doc = page_at(select_organisation_path)
      expect(row_names(doc)).to eq([I18n.t('navigation.overview')])
      expect(nav(doc).text).not_to include(I18n.t('navigation.organisations'))
      expect(nav(doc).at_css('nav')).to be_nil
    end
  end

  describe 'the help' do
    def help_doc
      get help_path
      follow_redirect! while response.redirect?
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body)
    end

    it 'shows the level sidebar without an organisation in the session' do
      doc = help_doc
      expect(row_names(doc)).to eq([I18n.t('navigation.overview'), I18n.t('navigation.all_inboxes'), I18n.t('navigation.people'),
                                    'Nord GmbH', 'Sued AG'])
      expect(nav(doc).css('a[aria-current]')).to be_empty
    end

    it 'shows the organisation of the session, not the level' do
      Prosopite.pause { get organisation_root_path(organisation_id: north.id) }
      doc = Prosopite.pause { help_doc }
      expect(doc.at_css('#sidebar')).to be_present
      expect(doc.at_css('#sidebar [data-all-inboxes-nav]')).to be_nil
      expect(doc.css('#sidebar [data-sidebar-layer-target="covered"] a').pluck('href'))
        .to include(a_string_starting_with("/org/#{north.id}/"))
    end
  end

  describe 'organisations the person is no active member of' do
    it 'leaves out an organisation whose membership was deactivated' do
      Prosopite.pause { south.memberships.where(user: user).update_all(active: false) }
      doc = page_at(select_organisation_path)
      expect(row_names(doc)).to include('Nord GmbH')
      expect(row_names(doc)).not_to include('Sued AG')
    end

    it 'leaves out an organisation whose membership was removed' do
      Prosopite.pause { south.memberships.where(user: user).delete_all }
      Prosopite.pause { make_token_owner_a_member(user, create(:organisation, name: 'Ost OHG')) }
      [select_organisation_path, all_inboxes_path].each do |path|
        doc = page_at(path)
        expect(row_names(doc)).to include('Nord GmbH', 'Ost OHG')
        expect(row_names(doc)).not_to include('Sued AG')
      end
    end
  end

  describe 'following an organisation row' do
    it 'opens that organisation and makes it the organisation of the session' do
      get organisation_root_path(organisation_id: north.id)
      expect(session[:current_organisation_id]).to eq(north.id)

      href = link(page_at(all_inboxes_path), 'Sued AG')['href']
      expect(session[:current_organisation_id]).to eq(north.id) # the inbox leaves it alone
      get href
      follow_redirect! while response.redirect?
      expect(response).to have_http_status(:ok)
      expect(request.path).to start_with(organisation_root_path(organisation_id: south.id))
      expect(session[:current_organisation_id]).to eq(south.id)
    end
  end

  describe 'the select field at the list' do
    it 'is what narrows the list, and the only control that carries the organisation' do
      doc = page_at(all_inboxes_path(org: south.id))
      expect(doc.css('.inbox-row').pluck('data-notification-id')).to eq([rows.last.id])
      expect(doc.css('select#inbox-organisation option[selected]').pluck('value')).to eq([south.id])
      # The links of the list's own tools keep the narrowing (a status, a view mode); none
      # leads to another organisation, and none stands in the sidebar. Only the select offers one.
      kept = doc.css("a[href*='org=']").map { |a| Rack::Utils.parse_query(URI.parse(a['href']).query)['org'] }
      expect(kept).to all(eq(south.id))
      expect(nav(doc).css("a[href*='org=']")).to be_empty
      expect(doc.css("select[name='org'] option").pluck('value')).to include(north.id, south.id)
    end
  end

  describe 'the form for a new organisation' do
    it 'shows the level sidebar with the counts, without a tenant' do
      doc = page_at(new_organisation_path)
      expect(organisation_rows(doc).map { |name, _, count| [name, count] }).to eq([['Nord GmbH', '2'], ['Sued AG', '1']])
      expect(nav(doc).css('a[aria-current]')).to be_empty
    end
  end
end
