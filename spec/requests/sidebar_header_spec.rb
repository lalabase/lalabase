# frozen_string_literal: true

require 'rails_helper'

# What: the header of the sidebar with the switcher (common/_sidebar_header, Belegungstabelle
#       F49, navigation plan PR 2). In an organisation, its management area and on the level
#       above the organisations, for every signed-in person; not on an account page.
# Why:  the menu leads across tenants. It must list only organisations with an active
#       membership, mark exactly where the reader stands, offer the invitation only with the
#       right, and keep the switch inside the management area in its section.
RSpec.describe 'The header of the sidebar with the switcher', :ci_guard, :real_transactions, type: :request do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }

  def member_of(org, admin: true, active: true)
    ActsAsTenant.with_tenant(org) do
      role = admin ? create(:admin_role, organisation: org) : create(:role, organisation: org, title: 'member')
      create(:membership, user: user, organisation: org, role: role, active: active)
    end
  end

  def unread_in(org)
    ActsAsTenant.with_tenant(org) do
      project = create(:project, organisation: org)
      ticket = create(:ticket, project: project)
      create(:notification, recipient: user, organisation: org, project: project, notifiable: ticket,
                            event_type: 'ticket_commented', channel: 'in_app', state: :delivered)
    end
  end

  def doc_at(path)
    get path
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def header(doc)
    doc.at_css('#sidebar [data-sidebar-header]')
  end

  def menu(doc)
    header(doc).at_css('details ul[data-details-autoclose-target="panel"]').tap { |ul| expect(ul).to be_present }
  end

  # [label, href, count, current?] per row of the menu, in order. The count is the marker's
  # (Neo::UnreadMarkerComponent): at zero it waits hidden for a broadcast, and that is no number.
  def menu_rows(doc)
    menu(doc).css('li > a, li form').map do |row|
      link = (row.name == 'form' ? row.at_css('button') : row).dup
      marker = link.at_css('[data-unread-marker]')
      count = marker && !marker['class'].to_s.split.include?('hidden') ? marker.text.squish : nil
      link.css('[data-unread-marker]').each(&:remove)
      [link.text.squish, row.name == 'form' ? row['action'] : row['href'], count, link['aria-current'] == 'true']
    end
  end

  before { sign_in user }

  after { ActsAsTenant.current_tenant = nil }

  describe 'for a person with north and south' do
    before do
      Prosopite.pause do
        member_of(north)
        member_of(south)
        2.times { unread_in(south) }
        unread_in(north)
      end
    end

    it 'names the organisation inside it and lists "Alle Organisationen", then the organisations, then the invitation' do
      doc = doc_at(organisation_root_path(organisation_id: north.id))
      expect(header(doc).at_css('summary h3').text.squish).to eq('Nord GmbH')
      expect(menu_rows(doc)).to eq([
                                     [I18n.t('navigation.all_organisations'), all_inboxes_path, nil, false],
                                     ['Nord GmbH', organisation_root_path(organisation_id: north.id), nil, true],
                                     ['Sued AG', organisation_root_path(organisation_id: south.id), '2', false],
                                     [I18n.t('navigation.invite_member'),
                                      new_organisation_invitation_path(organisation_id: north.id), nil, false]
                                   ])
      expect(menu(doc).at_css('[aria-current="true"] .bi-check-lg')).to be_present
      expect(menu(doc).css('.bi-check-lg').size).to eq(1)
      expect(doc.at_css('[data-all-inboxes-entry="switcher"]')).to be_nil
    end

    it 'keeps the live targets of the other organisations in the header' do
      doc = doc_at(organisation_root_path(organisation_id: north.id))
      expect(header(doc).at_css("#org_attention_count_#{south.id}")).to be_present
      expect(header(doc).at_css('#other_orgs_signal')).to be_present
      expect(header(doc).at_css("#org_attention_count_#{north.id}")).to be_nil
    end

    { 'the cockpit' => -> { select_organisation_path }, 'the inbox' => -> { all_inboxes_path } }.each do |where, path|
      it "names the level on #{where}, marks \"Alle Organisationen\" and counts every organisation" do
        doc = doc_at(instance_exec(&path))
        expect(header(doc).at_css('summary h3').text.squish).to eq(I18n.t('navigation.all_organisations'))
        expect(menu_rows(doc)).to eq([
                                       [I18n.t('navigation.all_organisations'), all_inboxes_path, nil, true],
                                       ['Nord GmbH', organisation_root_path(organisation_id: north.id), '1', false],
                                       ['Sued AG', organisation_root_path(organisation_id: south.id), '2', false]
                                     ])
        expect(menu(doc).at_css('a[aria-current="true"] .bi-check-lg')).to be_present
        expect(menu(doc).css('.bi-check-lg').size).to eq(1)
        expect(header(doc).at_css("a[href='#{organisation_settings_path(north)}']")).to be_nil
      end
    end

    it 'keeps the switch inside a management section a form that posts the section' do
      doc = doc_at(organisation_memberships_path(north))
      forms = menu(doc).css("form[action='#{set_organisation_path}']")
      expect(forms.size).to eq(2)
      forms.each do |form|
        expect(form.at_css('input[name="section"]')['value']).to eq('members')
        expect(form['method']).to eq('post')
      end
      expect(menu_rows(doc).first).to eq([I18n.t('navigation.all_organisations'), all_inboxes_path, nil, false])
    end

    it 'leaves out an organisation whose membership was deactivated, after showing the other one' do
      Prosopite.pause { south.memberships.where(user: user).update_all(active: false) }
      doc = doc_at(organisation_root_path(organisation_id: north.id))
      names = menu_rows(doc).map(&:first)
      expect(names).to include('Nord GmbH')
      expect(names).not_to include('Sued AG')
    end

    it 'marks the organisation inside a management section and gives it no number of its own' do
      doc = doc_at(organisation_memberships_path(north))
      current = menu(doc).css('[aria-current="true"]')
      expect(current.size).to eq(1)
      expect(current.first.text.squish).to start_with('Nord GmbH')
      expect(current.first.at_css('.bi-check-lg')).to be_present
      expect(menu(doc).at_css("#org_attention_count_#{north.id}")).to be_nil
      expect(menu(doc).at_css("#org_attention_count_#{south.id}")).to be_present
    end

    it 'switches inside a management section as a full load, not through Turbo' do
      doc = doc_at(organisation_memberships_path(north))
      forms = menu(doc).css("form[action='#{set_organisation_path}']")
      expect(forms.size).to eq(2)
      expect(forms.pluck('data-turbo')).to all(eq('false'))
    end

    { 'the cockpit' => -> { select_organisation_path }, 'the inbox' => -> { all_inboxes_path } }.each do |where, path|
      it "shows no dot of other organisations on #{where}: on the level every organisation counts in the menu" do
        doc = doc_at(instance_exec(&path))
        expect(menu(doc)).to be_present
        expect(header(doc).at_css('#other_orgs_signal')).to be_nil
      end
    end

    # Review PR 2 rounds 1 and 2: the answer to a row action redraws the counts of the level's
    # sidebar; the header beside it must not keep the old number, and only its numbers are
    # replaced (the menu stays as the reader left it).
    it 'carries the targets of its numbers on the inbox' do
      doc = doc_at(all_inboxes_path)
      expect(header(doc).at_css("#org_attention_count_#{north.id}")).to be_present
      expect(header(doc).at_css("#org_attention_count_#{south.id}")).to be_present
      expect(header(doc).at_css('#org_attention_count_overflow')).to be_present
    end

    it 'redraws the numbers of the header, and nothing else of it, with the answer to a row action' do
      south_row = Prosopite.pause { ActsAsTenant.without_tenant { Notification.where(recipient: user, organisation: south).first } }
      patch all_inbox_mark_read_path(south_row), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response).to have_http_status(:ok)
      streams = Nokogiri::HTML(response.body).css('turbo-stream')
      expect(streams.pluck('target')).not_to include('sidebar_header')
      count_of = lambda do |id|
        marker = streams.find { |stream| stream['target'] == id }.at_css('template [data-unread-marker]')
        marker['class'].to_s.split.include?('hidden') ? nil : marker.text.squish
      end
      expect(count_of.call("org_attention_count_#{north.id}")).to eq('1')
      expect(count_of.call("org_attention_count_#{south.id}")).to eq('1')
      expect(count_of.call('org_attention_count_overflow')).to be_nil
    end

    it 'draws the menu with a soft shadow (F29) and no written hard shadow' do
      doc = doc_at(organisation_root_path(organisation_id: north.id))
      expect(menu(doc)['class'].split).to include('shadow-md', 'bg-surface-raised', 'border-cream-300', 'rounded-lg')
      expect(header(doc).to_html).not_to include('shadow-[')
    end
  end

  describe 'for a person with one organisation and no right to invite' do
    before { Prosopite.pause { member_of(north, admin: false) } }

    it 'renders, with "Alle Organisationen" leading to the cockpit' do
      doc = doc_at(organisation_root_path(organisation_id: north.id))
      expect(menu_rows(doc)).to eq([
                                     [I18n.t('navigation.all_organisations'), select_organisation_path, nil, false],
                                     ['Nord GmbH', organisation_root_path(organisation_id: north.id), nil, true]
                                   ])
    end

    it 'renders on the cockpit too, with the level marked' do
      doc = doc_at(select_organisation_path)
      expect(menu_rows(doc)).to eq([
                                     [I18n.t('navigation.all_organisations'), select_organisation_path, nil, true],
                                     ['Nord GmbH', organisation_root_path(organisation_id: north.id), nil, false]
                                   ])
    end
  end

  describe 'more organisations than the menu holds' do
    let(:orgs) do
      (1..(NavigationHelper::ORG_MENU_LIMIT + 1)).map { |n| create(:organisation, name: format('Firma %02d', n)) }
    end

    before do
      Prosopite.pause do
        orgs.each { |org| member_of(org) }
        2.times { unread_in(orgs.last) } # sorts past the cap
      end
    end

    it 'counts the hits beyond the cap at "Alle Organisationen" on the level as well' do
      doc = doc_at(select_organisation_path)
      expect(menu_rows(doc).first).to eq([I18n.t('navigation.all_organisations'), all_inboxes_path, '2', true])
    end

    it 'counts the hits beyond the cap at "Alle Organisationen"' do
      doc = doc_at(organisation_root_path(organisation_id: orgs.first.id))
      rows = menu_rows(doc)
      expect(rows.map(&:first)).not_to include(orgs.last.name)
      expect(rows.first).to eq([I18n.t('navigation.all_organisations'), all_inboxes_path, '2', false])
    end
  end

  describe 'the invitation' do
    before { Prosopite.pause { member_of(north) } }

    it 'shows inside an organisation with the right, and never on the level' do
      inside = doc_at(organisation_root_path(organisation_id: north.id))
      expect(menu_rows(inside).map(&:first)).to include(I18n.t('navigation.invite_member'))

      level = doc_at(select_organisation_path)
      expect(menu_rows(level).map(&:first)).to eq([I18n.t('navigation.all_organisations'), 'Nord GmbH'])
    end
  end

  describe 'on a page of the account' do
    before { Prosopite.pause { member_of(north) } }

    it 'does not render' do
      doc = doc_at(edit_user_preferences_path)
      expect(doc.at_css('#sidebar [data-account-nav-list]')).to be_present
      expect(header(doc)).to be_nil
    end
  end
end
