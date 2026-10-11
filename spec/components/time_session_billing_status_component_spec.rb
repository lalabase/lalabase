# frozen_string_literal: true

require 'rails_helper'

# The badge that says where ONE time session stands in billing.
#
# Why this file starts with a rendering test at all: the component called its
# route helper directly (organisation_time_session_group_path(...)) instead of
# through `helpers`. In a REQUEST that works -- the component picks the route set
# up from the view context. Under rspec it does not: ViewComponent::Base._routes
# is nil in the test environment, and the test environment also mixes
# ActionDispatch::Routing::UrlFor into Object, so `nil.url_for(hash, name,
# strategy, method)` lands on that module's one-argument #url_for and raises
# "wrong number of arguments (given 4, expected 0..1)".
#
# The effect was not a broken page. It was that NO spec could render this
# component with a grouped session, which is why its main branch had no coverage
# at all. Going through `helpers` (what every tested component here does, e.g.
# SubjectTimeSummaryComponent) works in both, and buys the examples below.
RSpec.describe TimeSessionBillingStatusComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  def session(group: nil, billed: false, invoice: nil)
    create(:time_session, project: project, organisation: organisation, creator: user,
                          duration: 30, billed: billed, invoice_number: invoice,
                          time_session_group_id: group&.id, occurred_on: 2.days.ago)
  end

  let(:open_group) { create(:time_session_group, organisation: organisation, name: 'August') }
  let(:billed_group) do
    create(:time_session_group, organisation: organisation, name: 'Juli', billed: true, invoice_number: 'INV-7')
  end

  describe 'a session in an open billing' do
    it 'renders, and links to that billing' do
      render_inline(described_class.new(time_session: session(group: open_group)))

      expect(page).to have_link(href: "/org/#{organisation.id}/time_session_groups/#{open_group.id}")
    end

    it 'names the billing it belongs to' do
      render_inline(described_class.new(time_session: session(group: open_group)))

      expect(page.text).to include('August')
    end
  end

  describe 'a billed session' do
    it 'renders and says so' do
      render_inline(described_class.new(time_session: session(group: billed_group, billed: true, invoice: 'INV-7')))

      expect(page.text).to include(I18n.t('views.time_sessions.billing_status.billed'))
      expect(page).to have_css('i.bi-check-circle')
    end
  end

  describe 'without the link' do
    it 'renders the badge as plain text' do
      render_inline(described_class.new(time_session: session(group: open_group), show_link: false))

      expect(page).to have_no_link
      expect(page.text).to include('August')
    end
  end

  # render? gates on grouped? -- a session in no billing has no badge to show.
  describe 'a session in no billing' do
    it 'renders nothing at all' do
      render_inline(described_class.new(time_session: session))

      expect(page.text.strip).to be_empty
    end
  end
end
