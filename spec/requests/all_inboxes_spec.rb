# frozen_string_literal: true

require 'rails_helper'

# What: the inbox above the organisations ("Gesamt-Inbox", GET /inbox). One list
#       over every organisation a person is an active member of: each row names
#       its organisation and leaves for that organisation's inbox with the row
#       open. The rows are the ones the organisation's own inbox shows (the one
#       inbox rule, per organisation), and looking at the page never moves the
#       organisation the session works in.
# Why:  a person with one organisation per customer had to visit every inbox in
#       turn. The page reads across tenants, so everything it must NOT show is
#       pinned here: another person's rows, a lost project, a left organisation.
RSpec.describe 'Inbox above the organisations', :ci_guard, type: :request do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }

  def project_in(org, **attributes)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org, **attributes) }
  end

  def ticket_row(org, project, title, recipient: user, state: :delivered, created_at: Time.current)
    ActsAsTenant.with_tenant(org) do
      ticket = create(:ticket, project: project, title: title)
      create(:notification, recipient: recipient, organisation: org, project: project, notifiable: ticket,
                            event_type: 'ticket_commented', channel: 'in_app', state: state, created_at: created_at,
                            read_at: %i[read archived].include?(state) ? 1.hour.ago : nil,
                            archived_at: state == :archived ? 1.hour.ago : nil)
    end
  end

  let(:north_project) { project_in(north, name: 'Lager') }
  let(:south_project) { project_in(south, name: 'Versand') }

  # The fixtures repeat lookups per organisation (memberships, rights); the
  # requests below are what Prosopite watches.
  let!(:north_row) do
    Prosopite.pause do
      make_token_owner_a_member(user, north, projects: [north_project])
      ticket_row(north, north_project, 'Regal wackelt', created_at: 2.hours.ago)
    end
  end
  let!(:south_row) do
    Prosopite.pause do
      make_token_owner_a_member(user, south, projects: [south_project])
      ticket_row(south, south_project, 'Paket fehlt', created_at: 1.hour.ago)
    end
  end

  before { sign_in user }

  after { ActsAsTenant.current_tenant = nil }

  def page(**params)
    get all_inboxes_path(**params)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def row_of(doc, notification)
    doc.at_css(%(.inbox-row[data-notification-id="#{notification.id}"]))
  end

  def listed_ids(doc)
    doc.css('.inbox-row').pluck('data-notification-id')
  end

  describe 'the list' do
    it 'shows the rows of every organisation in one list, newest first' do
      expect(listed_ids(page)).to eq([south_row.id, north_row.id])
    end

    it 'names the organisation on every row' do
      doc = page
      expect(row_of(doc, north_row).at_css('.inbox-row__meta-text').text).to start_with('Nordwind GmbH · ')
      expect(row_of(doc, south_row).at_css('.inbox-row__meta-text').text).to start_with('Suedhang AG · ')
    end

    it 'leads a row into the inbox of its own organisation, with the row open' do
      link = row_of(page, south_row).at_css('a.inbox-row__link')
      expect(link['href']).to start_with(organisation_notifications_path(south))
      expect(Rack::Utils.parse_nested_query(URI(link['href']).query)).to include('notification' => south_row.id)
      expect(link['data-turbo-frame']).to eq('_top')
    end

    it 'offers no bulk action yet: no bulk checkbox, no bulk bar (the row menu: all_inboxes_row_actions_spec)' do
      doc = page
      expect(doc.css('.inbox-row')).not_to be_empty
      expect(doc.css('.inbox-row__check, .inbox-bulk')).to be_empty
    end

    it 'carries the title of the page above, not the one of an organisation' do
      expect(page.at_css('.people-head').text).to include(I18n.t('views.all_inboxes.title'))
    end

    it 'counts the unread rows of all organisations at "Ungelesen"' do
      Prosopite.pause { ticket_row(north, north_project, 'Schon gelesen', state: :read) }
      expect(page.at_css('.list-tab-bar__tabs').text).to match(/\b2\b/)
    end

    it 'opens a row in the list it stood in: unread and read by default, the chosen view otherwise' do
      default_link = row_of(page, south_row).at_css('a.inbox-row__link')['href']
      expect(Rack::Utils.parse_nested_query(URI(default_link).query)['state_filters']).to eq(%w[read unread])

      archived = Prosopite.pause { ticket_row(south, south_project, 'Abgelegt', state: :archived) }
      archived_link = row_of(page(state_filters: %w[archived]), archived).at_css('a.inbox-row__link')['href']
      expect(Rack::Utils.parse_nested_query(URI(archived_link).query)['state_filters']).to eq(%w[archived])
    end

    it 'lists in-app rows only, never the mail twin of a notification' do
      mailed = Prosopite.pause do
        ActsAsTenant.with_tenant(north) do
          create(:notification, recipient: user, organisation: north, project: north_project,
                                notifiable: north_row.notifiable, event_type: 'ticket_commented',
                                channel: 'email', state: :delivered)
        end
      end
      doc = page(view_mode: 'chronological')
      expect(listed_ids(doc)).to include(north_row.id)
      expect(listed_ids(doc)).not_to include(mailed.id)
    end

    it 'reads a type that does not exist and an unknown period as no filter' do
      doc = page(event_type: 'no_such_type', period: 'no_such_period')
      expect(listed_ids(doc)).to contain_exactly(north_row.id, south_row.id)
      expect(doc.css('.list-tab-bar__tabs a').pluck('href').join).not_to include('no_such_type')
    end

    it 'loads its next pages from /inbox and searches there' do
      doc = page
      expect(doc.at_css('[data-controller~="neo-endless-scroll"]')['data-neo-endless-scroll-url-value'])
        .to eq(all_inboxes_path)
      expect(doc.at_css('form.inbox-search')['action']).to eq(all_inboxes_path)
    end

    it 'redraws the tools and the view switch with a search, and only then' do
      expect(page.css('turbo-stream')).to be_empty

      get all_inboxes_path(search: 'Regal'), headers: { 'Turbo-Frame' => 'notifications_list_frame' }
      targets = Nokogiri::HTML(response.body).css('turbo-stream[action="replace"]').pluck('target')
      expect(targets).to contain_exactly('inbox_list_tools', 'inbox_view_switch')
    end

    it 'shows the archive across organisations' do
      archived = Prosopite.pause { ticket_row(south, south_project, 'Abgelegt', state: :archived) }
      doc = page(state_filters: %w[archived])
      expect(listed_ids(doc)).to eq([archived.id])
    end

    it 'searches the rows of every organisation by title' do
      expect(listed_ids(page(search: 'Regal'))).to eq([north_row.id])
    end

    it 'renders a row of every kind of subject without a tenant' do
      rows = Prosopite.pause do
        ActsAsTenant.with_tenant(north) do
          ProjectPermission.find_by!(user: user, project: north_project)
                           .update!(notes_access: 'read_write', documents_access: 'read_write')
          # A document reads its title from its current version, a tenanted
          # record the list's preload does not reach by itself.
          document = create(:document, project: north_project, organisation: north, creator: user)
          document.update!(current_version: create(:document_version, document: document, organisation: north,
                                                                      title: 'Rahmenvertrag'))
          subjects = [create(:note, project: north_project), document, north_project, north]
          subjects.map do |subject|
            create(:notification, recipient: user, organisation: north, project: (north_project unless subject == north),
                                  notifiable: subject, event_type: 'system_message', channel: 'in_app',
                                  state: :delivered)
          end
        end
      end
      Prosopite.pause { expect(listed_ids(page(view_mode: 'chronological'))).to include(*rows.map(&:id)) }
      expect(response.body).to include('Rahmenvertrag')
    end
  end

  describe 'one organisation of the list' do
    it 'narrows the list to it and keeps the others in the sidebar with their counts' do
      doc = page(org: north.id)
      expect(listed_ids(doc)).to eq([north_row.id])
      nav = doc.at_css('[data-all-inboxes-nav]')
      expect(nav.text).to include('Nordwind GmbH', 'Suedhang AG')
      south_link = nav.css('a').find { |a| a.text.include?('Suedhang AG') }
      expect(south_link['href']).to eq(all_inboxes_path(org: south.id))
    end

    # North with two unread rows, south with one, a third organisation with none.
    context 'with different counts per organisation' do
      let(:quiet) { create(:organisation, name: 'Stille KG') }

      before do
        Prosopite.pause do
          ticket_row(north, north_project, 'Zweite Meldung')
          make_token_owner_a_member(user, quiet, projects: [project_in(quiet)])
        end
      end

      def nav_link(doc, name)
        doc.at_css('[data-all-inboxes-nav]').css('a').find { |a| a.text.include?(name) }
      end

      def count_at(link)
        link.text.squish[/\d+\z/]
      end

      it 'shows each organisation its own unread count in the sidebar, and none at zero' do
        doc = page
        expect(count_at(nav_link(doc, 'Nordwind GmbH'))).to eq('2')
        expect(count_at(nav_link(doc, 'Suedhang AG'))).to eq('1')
        expect(nav_link(doc, 'Stille KG').text.squish).to eq('Stille KG')
      end

      it 'names the counts in the select and offers the ids as values' do
        options = page.css('select#inbox-organisation option')
        expect(options.map(&:text)).to eq(['Alle Organisationen', 'Nordwind GmbH (2)', 'Stille KG', 'Suedhang AG (1)'])
        expect(options.pluck('value')).to eq(['', north.id, quiet.id, south.id])
      end

      it 'counts at "Ungelesen" what the chosen organisation holds, not all of them' do
        expect(page(org: south.id).at_css('#inbox_unread_count').text.strip).to eq('1')
        expect(page.at_css('#inbox_unread_count').text.strip).to eq('3')
      end

      it 'says of an organisation without rows that nothing matches, with the way back to all' do
        doc = page(org: quiet.id)
        expect(listed_ids(doc)).to be_empty
        expect(doc.at_css('.inbox-empty').text).to include(I18n.t('views.organisations.notifications.master_list.empty.no_match.title'))
        expect(doc.at_css('.inbox-empty a')['href']).to eq(all_inboxes_path)
      end
    end

    it 'marks the open organisation in the sidebar and in the select, and "Gesamt-Inbox" only without one' do
      marks = lambda do |doc|
        doc.at_css('[data-all-inboxes-nav]').css('a').to_h { |a| [a.text.squish.sub(/ \d+\z/, ''), a['aria-current']] }
      end

      expect(marks.call(page)).to include(I18n.t('navigation.all_inboxes') => 'page', 'Nordwind GmbH' => nil,
                                          'Suedhang AG' => nil)

      doc = page(org: south.id)
      expect(marks.call(doc)).to include(I18n.t('navigation.all_inboxes') => nil, 'Nordwind GmbH' => nil,
                                         'Suedhang AG' => 'true')
      expect(doc.css('[data-all-inboxes-nav] a.sidebar-row--active').map { |a| a.text.squish.sub(/ \d+\z/, '') })
        .to eq(['Suedhang AG'])
      expect(doc.css('select#inbox-organisation option[selected]').pluck('value')).to eq([south.id])
      expect(page.css('select#inbox-organisation option[selected]')).to be_empty
    end

    it 'keeps the status view when an organisation is chosen in the select' do
      form = page(state_filters: %w[archived]).at_css('form[data-inbox-tool="organisation"]')
      expect(form['action']).to eq(all_inboxes_path)
      expect(form.css('input[type="hidden"][name="state_filters[]"]').pluck('value')).to eq(%w[archived])
    end

    it 'shows the archive of the chosen organisation' do
      archived = Prosopite.pause { ticket_row(south, south_project, 'Abgelegt', state: :archived) }
      Prosopite.pause { ticket_row(north, north_project, 'Auch abgelegt', state: :archived) }
      expect(listed_ids(page(org: south.id, state_filters: %w[archived]))).to eq([archived.id])
    end

    it 'keeps the organisation in the links of the status views' do
      hrefs = page(org: north.id).css('.list-tab-bar__tabs a').pluck('href')
      expect(hrefs).to all(include("org=#{north.id}"))
    end

    it 'answers an organisation of somebody else exactly like one that does not exist' do
      foreign = create(:organisation)
      get all_inboxes_path(org: foreign.id)
      expect(response).to have_http_status(:not_found)
      foreign_body = response.body

      get all_inboxes_path(org: SecureRandom.uuid)
      expect(response).to have_http_status(:not_found)
      expect(response.body).to eq(foreign_body)

      get all_inboxes_path(org: 'no-uuid')
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'what the page must not show' do
    it "never lists another person's row" do
      colleague = create(:user)
      theirs = Prosopite.pause do
        make_token_owner_a_member(colleague, north, projects: [north_project])
        ticket_row(north, north_project, 'Nicht deins', recipient: colleague)
      end
      doc = page
      expect(listed_ids(doc)).to include(north_row.id)
      expect(listed_ids(doc)).not_to include(theirs.id)
      expect(response.body).not_to include('Nicht deins')
    end

    it 'drops the rows of a project the person lost' do
      hidden_project = project_in(south, name: 'Geheim')
      Prosopite.pause { ticket_row(south, hidden_project, 'Hinter der Tuer') }
      doc = page
      expect(listed_ids(doc)).to contain_exactly(north_row.id, south_row.id)
      expect(response.body).not_to include('Hinter der Tuer')
    end

    it 'drops the rows of an archived project' do
      ActsAsTenant.with_tenant(south) { south_project.update!(archived_at: 1.day.ago) }
      expect(listed_ids(page)).to eq([north_row.id])
    end

    it 'drops an organisation the person was deactivated in, rows and name' do
      third = create(:organisation, name: 'Dritte KG')
      Prosopite.pause do
        project = project_in(third)
        make_token_owner_a_member(user, third, projects: [project])
        ticket_row(third, project, 'Aus alter Zeit')
        Membership.find_by(user: user, organisation: third).update!(active: false)
      end
      doc = page
      expect(listed_ids(doc)).to contain_exactly(north_row.id, south_row.id)
      expect(response.body).not_to include('Dritte KG', 'Aus alter Zeit')
    end
  end

  describe 'the session' do
    it 'keeps working in the organisation it was in' do
      get organisation_notifications_path(north, state_filters: %w[read unread])
      expect(session[:current_organisation_id]).to eq(north.id)

      page(org: south.id)
      expect(session[:current_organisation_id]).to eq(north.id)
    end
  end

  describe 'who gets the page' do
    it 'sends a person with one organisation to the inbox of that organisation' do
      Membership.find_by(user: user, organisation: south).update!(active: false)
      get all_inboxes_path
      expect(response).to redirect_to(organisation_notifications_path(north))
    end

    it 'sends a person without any organisation where such a person belongs, not to an empty list' do
      sign_out user
      sign_in create(:user)
      get all_inboxes_path
      expect(response).to redirect_to(select_organisation_path)
    end

    it 'asks a visitor to sign in' do
      sign_out user
      get all_inboxes_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
