# frozen_string_literal: true

require 'rails_helper'

# The billings table (P3 of doc/abrechnungen_filterzeile_und_tabelle_plan.md):
# what a row states and what the footer sums. Pinned here:
# * the status cell: dot plus the SHARED billing word (never a local vocabulary)
# * the invoice cell: the number once billed, the muted "ohne Nummer" before
# * the subline: at most two project names plus "+n", or "noch keine Zeiten"
# * the row menu: entries follow the policy lines, the delete link speaks
#   turbo_method/turbo_confirm (rails-ujs is not loaded in this app)
# * the sum footer: what is ON SCREEN, from the precomputed aggregates
# * the empty state: names the filter as the reason when one emptied the list
RSpec.describe 'Billings list: the table', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:project_a) { with_tenant { create(:project, organisation: organisation, name: 'Alpha') } }
  let(:project_b) { with_tenant { create(:project, organisation: organisation, name: 'Beta') } }
  let(:project_c) { with_tenant { create(:project, organisation: organisation, name: 'Gamma') } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant { create(:membership, user: admin, organisation: organisation, role: admin_role, active: true) }
    sign_in admin
  end

  after { ActsAsTenant.current_tenant = nil }

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def create_group(projects: [], minutes: 60, **attrs)
    with_tenant do
      group = create(:time_session_group, organisation: organisation, creator: admin, **attrs)
      projects.each do |project|
        create(:time_session, time_session_group: group, project: project,
                              organisation: organisation, creator: admin, duration: minutes)
      end
      group
    end
  end

  def get_list(**params)
    get organisation_time_session_groups_path(organisation, **params)
    expect(response).to have_http_status(:ok)
  end

  def doc = Nokogiri::HTML(response.body)

  # The DESKTOP row: the mobile card links the same address earlier in the
  # document, so "first link with this id" finds the card, whose ancestors hold
  # no row. Filter by the row wrapper instead of by document order.
  def row_of(group)
    doc.css(%(a[href$="#{group.id}"])).filter_map { |a| a.ancestors('div.group').first }.first
  end

  it 'stretches the name link across the whole row' do
    group = create_group(projects: [project_a])

    get_list

    # The overlay classes are the mechanism: without them the row is only
    # clickable on the name's own letters (user, 02.09.).
    name_link = row_of(group).at_css('a')
    expect(name_link['class']).to include('after:absolute', 'after:inset-0')
  end

  it 'states the shared billing word beside the dot, never a local one' do
    open_group = create_group(projects: [project_a])
    billed_group = create_group(projects: [project_a], billed: true, invoice_number: 'RE-2026-118')

    get_list

    expect(row_of(open_group).text).to include(I18n.t('views.time_sessions.billing_status.in_billing'))
    expect(row_of(billed_group).text).to include(I18n.t('views.time_sessions.billing_status.billed'))
    expect(response.body).not_to include('translation_missing')
  end

  it 'shows the invoice number once billed and the muted placeholder before' do
    open_group = create_group(projects: [project_a])
    billed_group = create_group(projects: [project_a], billed: true, invoice_number: 'RE-2026-118')

    get_list

    expect(row_of(billed_group).text).to include('RE-2026-118')
    expect(row_of(open_group).text)
      .to include(I18n.t('views.organisations.time_session_groups.groups_list.without_number'))
  end

  it 'sublines at most two project names plus how many more, sorted' do
    wide_group = create_group(projects: [project_c, project_a, project_b])
    empty_group = create_group

    get_list

    expect(row_of(wide_group).text).to include('Alpha · Beta +1')
    expect(row_of(empty_group).text)
      .to include(I18n.t('views.organisations.time_session_groups.groups_list.no_sessions_yet'))
  end

  it 'sums the visible rows in the footer' do
    create_group(projects: [project_a, project_b], minutes: 45)
    create_group(projects: [project_a], minutes: 30)

    get_list

    footer = doc.css('.hidden.md\\:block > div').last
    expect(footer.text).to include(I18n.t('views.organisations.time_session_groups.groups_list.visible_sum'))
    expect(footer.text).to include('3')
    expect(footer.text).to include('02:00')
  end

  describe 'the row menu' do
    it 'offers view, edit and a Turbo-speaking delete to the admin on an open billing' do
      group = create_group(projects: [project_a])

      get_list

      menu = row_of(group).at_css('details')
      links = menu.css('a')
      # D4: the status modal's trigger sits between edit and delete.
      expect(links.map { |l| l.text.strip })
        .to eq([I18n.t('views.organisations.time_session_groups.groups_list.menu_view_times'),
                I18n.t('views.organisations.time_session_groups.groups_list.menu_edit'),
                I18n.t('views.organisations.time_session_groups.show_header.bill_button'),
                I18n.t('views.organisations.time_session_groups.groups_list.menu_delete')])

      delete_link = links.last
      expect(delete_link['data-turbo-method']).to eq('delete')
      expect(delete_link['data-turbo-confirm']).to be_present
    end

    it 'drops the edit entry once the billing is billed' do
      group = create_group(projects: [project_a], billed: true, invoice_number: 'RE-1')

      get_list

      labels = row_of(group).at_css('details').css('a').map { |l| l.text.strip }
      expect(labels).not_to include(I18n.t('views.organisations.time_session_groups.groups_list.menu_edit'))
      expect(labels).to include(I18n.t('views.organisations.time_session_groups.groups_list.menu_view_times'))
      # D4: a billed billing offers the way back out of the billed state.
      expect(labels).to include(I18n.t('views.organisations.time_session_groups.billing_status.submit_unbill'))
    end
  end

  describe 'the empty states' do
    it 'blames the filter when one emptied the list' do
      create_group(projects: [project_a], name: 'Findbar')

      get_list(search: 'zzz-nichts')

      expect(response.body)
        .to include(I18n.t('views.organisations.time_session_groups.groups_list.empty_filtered'))
    end

    it 'says there is nothing yet on the bare page of a fresh organisation' do
      get_list

      expect(response.body)
        .to include(I18n.t('views.organisations.time_session_groups.groups_list.no_groups_available'))
    end
  end
end
