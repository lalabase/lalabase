# frozen_string_literal: true

# Onboarding banner on the organisation overview (Kettenglied 0,
# doc/onboarding_plan.md D4). Pins the banner's full lifecycle: visible after
# seeding (on exactly the screen the observed first user failed on), gone when
# every tutorial ticket is done (same closed-status semantics as
# my_open_tickets), gone after personal dismissal — and dismissal is scoped
# per user + organisation, so a second organisation starts fresh.
require 'rails_helper'

RSpec.describe 'Organisations::OnboardingBanner', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def seed!
    Actors::SeedOnboarding.call(organisation: organisation, current_user: user)
  end

  def tutorial_project
    organisation.projects.find_by(system_kind: 'onboarding')
  end

  describe 'GET overview (briefings#show)' do
    it 'shows the banner while the seeded tutorial project has open tickets' do
      seed!
      get organisation_root_path(organisation)

      expect(response.body).to include('data-testid="onboarding-banner"')
      expect(response.body).to include(I18n.t('views.organisations.briefings.onboarding_banner.title'))
    end

    it 'shows no banner without an onboarding project' do
      get organisation_root_path(organisation)

      expect(response.body).not_to include('data-testid="onboarding-banner"')
    end

    it 'shows no banner once every tutorial ticket is done' do
      seed!
      tutorial_project.tickets.find_each do |ticket|
        ticket.update!(custom_attributes: ticket.custom_attributes.merge('status' => 'resolved'))
      end

      get organisation_root_path(organisation)

      expect(response.body).not_to include('data-testid="onboarding-banner"')
    end

    # Boundary n-1: with ONE ticket still open the banner must stay. Kills
    # mutations of the lifetime check (exists? → "all done", count flips).
    it 'still shows the banner while a single tutorial ticket remains open' do
      seed!
      tutorial_project.tickets.order(:number).limit(3).each do |ticket|
        ticket.update!(custom_attributes: ticket.custom_attributes.merge('status' => 'resolved'))
      end

      get organisation_root_path(organisation)

      expect(response.body).to include('data-testid="onboarding-banner"')
    end

    # The lookup must key on system_kind, not on "some project exists"
    # (mutation: find_by(system_kind:) degraded to projects.first).
    it 'shows no banner for a regular project without the onboarding marker' do
      create(:project, organisation: organisation, name: 'Kundenprojekt')

      get organisation_root_path(organisation)

      expect(response.body).not_to include('data-testid="onboarding-banner"')
    end
  end

  describe 'DELETE dismissal' do
    it 'persists the dismissal and hides the banner on the next render' do
      seed!

      delete organisation_onboarding_banner_path(organisation)
      expect(response).to redirect_to(organisation_root_path(organisation))

      get organisation_root_path(organisation)
      expect(response.body).not_to include('data-testid="onboarding-banner"')
    end

    it 'scopes the dismissal to user + organisation (a second org starts fresh)' do
      seed!
      delete organisation_onboarding_banner_path(organisation)

      store = user.reload.preference_store
      expect(store.onboarding_banner_dismissed?(organisation)).to be(true)
      other_org = ActsAsTenant.without_tenant { create(:organisation) }
      expect(store.onboarding_banner_dismissed?(other_org)).to be(false)
    end
  end
end
