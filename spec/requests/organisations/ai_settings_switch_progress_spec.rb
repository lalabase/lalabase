# frozen_string_literal: true

# What: GET /ai_settings — the two things KI-Pakete P4c adds to the package
#   catalogue: the progress notice for a switch already underway (plan E1) and the
#   org's OWN package card when the grid would not show it (E5).
# Type: Request spec.
# Why (philosophy): P4b opened the card doors, so from the first customer switch on
#   this page is the only place that says what a paid, hours-long re-embedding is
#   doing. These examples assert the STATEMENTS, not the markup — that a paused run
#   says paused, that a pointer-less org is not told its content stays findable when
#   it does not, and that an org sitting on a hidden or withdrawn package can still
#   see and (where allowed) operate it.
# Contract: the notice appears only while a switch is pending and names the state;
#   the current package's card is prepended when it is outside the grid, WITHOUT
#   swallowing the empty-filter hint; and a withdrawn package's rung switcher is
#   rendered dead, because Actors::SelectAiPackage refuses every write on it.

require 'rails_helper'

RSpec.describe 'Organisations::AiSettings switch progress and own-package card (P4c)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user) }
  let(:admin_role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  # The org's own lane. Without a resolvable one the switch guard fails closed and
  # the catalogue renders every card as blocked — see the P4b dialog spec.
  let!(:system_credential) do
    create(:ai_credential, provider: 'openai', active: true, enabled: true)
  end

  # Same derivation as the P4b dialog spec: the jurisdiction is validated against the
  # pair the CREDENTIALS produce, so a package that should be hidden by the strict
  # default filter has to be given credentials that actually place it outside the EU.
  def publish_package(name:, jurisdiction: 'eu_native')
    domicile_eu, region_eu = AiPackage::JURISDICTION_MATRIX.key(jurisdiction) || [false, false]
    credential = create(:ai_credential, region: region_eu ? 'eu' : 'us',
                                        company_domicile: domicile_eu ? 'eu' : 'non_eu')
    package = build(:ai_package, name: name, jurisdiction: jurisdiction, active: true,
                                 embedding_credential: credential,
                                 embedding_model: 'text-embedding-3-small', embedding_dims: 1536)
    AiPackageTier::KEYS.each_with_index do |key, index|
      package.tiers << build(:ai_package_tier, ai_package: package, key: key,
                                               label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                                               chat_credential: credential, position: index)
    end
    package.save!
    package
  end

  def progress_t(key)
    I18n.t("views.organisations.ai_settings.packages.progress.#{key}")
  end

  def outside_t(key)
    I18n.t("views.organisations.ai_settings.packages.outside_grid.#{key}")
  end

  # A pointer at a triple OTHER than the configured one — a staged switch underway.
  def point_at_other_space
    space = ActsAsTenant.with_tenant(organisation) do
      create(:embedding_space, organisation: organisation,
                               embedding_model: 'text-embedding-3-large', embedding_dims: 3072)
    end
    organisation.update_column(:active_embedding_space_id, space.id)
  end

  def corpus
    ActsAsTenant.with_tenant(organisation) do
      create(:code_symbol, organisation: organisation, signature: 'a' * 40)
    end
  end

  before { sign_in admin }

  describe 'the progress notice' do
    it 'is absent for an organisation with no switch underway' do
      space = ActsAsTenant.with_tenant(organisation) { create(:embedding_space, organisation: organisation) }
      organisation.update_column(:active_embedding_space_id, space.id)

      get organisation_ai_settings_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('data-switch-progress')
    end

    it 'names the running rebuild and promises only what the old index can keep' do
      corpus
      point_at_other_space

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include('data-switch-progress="building"')
      expect(response.body).to include(progress_t('building_title'))
      expect(response.body).to include(
        I18n.t('views.organisations.ai_settings.packages.progress.building_body',
               remaining: 1, total: 1, percent: 0)
      )
      # Every state that reaches the notice has a resolved pointer, so the old space
      # keeps serving and this sentence is true throughout.
      expect(response.body).to include(progress_t('search_kept'))
    end

    # The correction of P4c's own blocker 1. An org with no pointer has reads and
    # writes on the SAME space — its search works perfectly — so the notice must not
    # appear at all. It did, for every such org, with a warning triangle and a "please
    # contact your administrator". With the production pointer count at zero that
    # would have been every organisation on the platform after the next deploy.
    it 'stays silent for an organisation with no pointer instead of warning it' do
      corpus

      get organisation_ai_settings_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(organisation.reload.active_embedding_space_id).to be_nil
      expect(response.body).not_to include('data-switch-progress')
    end

    # A frozen number with no explanation is the failure mode here: the customer
    # reloads, nothing moves, and nothing on the page says the run is waiting for
    # next month's budget rather than being slow.
    it 'says a metered run is paused rather than showing a stalled bar' do
      corpus
      point_at_other_space
      system_credential.update!(included_in_quota: true)
      organisation.update!(ai_quota_credits_override: 0, ai_quota_buffer_override: 0)

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include('data-switch-progress="paused"')
      expect(response.body).to include(progress_t('paused_title'))
      expect(response.body).not_to include(progress_t('building_title'))
    end
  end

  describe "the org's own package when the grid does not show it (E5)" do
    # Hidden by the STRICT DEFAULT filter, not withdrawn: the package is published
    # and selectable, the customer simply has not widened the catalogue to a rung
    # that makes a third-country claim.
    context 'when the filters hide it' do
      let!(:package) { publish_package(name: 'Weltweit', jurisdiction: 'non_eu') }

      before { organisation.update_column(:ai_package_id, package.id) }

      it 'prepends the card with a working rung switcher' do
        get organisation_ai_settings_path(organisation)

        expect(response.body).to include(outside_t('filtered_title'))
        expect(response.body).to include("data-package-card=\"#{package.id}\"")
        # The rung switcher is LIVE here — that hidden field only exists inside the
        # button_to the tier switch renders.
        expect(response.body).to include('ai_package_tier_key')
        expect(response.body).not_to include(outside_t('withdrawn_title'))
      end

      # Two independent questions, and folding them into one branch would swallow
      # this hint — the only thing on the page that names the relaxation which
      # brings the catalogue back (§7.1).
      it 'still shows the empty-filter hint when no package matches' do
        get organisation_ai_settings_path(organisation)

        expect(response.body).to include(
          I18n.t('views.organisations.ai_settings.packages.empty.title')
        )
        expect(response.body).to include(outside_t('filtered_title'))
      end
    end

    context 'when the operator has withdrawn it' do
      let!(:package) { publish_package(name: 'Eingestellt') }

      before do
        organisation.update_column(:ai_package_id, package.id)
        package.update_column(:active, false)
      end

      it 'shows the card and the way out, but no rung switcher that would bounce' do
        get organisation_ai_settings_path(organisation)

        expect(response.body).to include(outside_t('withdrawn_title'))
        expect(response.body).to include(outside_t('withdrawn_body'))
        expect(response.body).to include("data-package-card=\"#{package.id}\"")
        expect(response.body).to include(
          I18n.t('views.organisations.ai_settings.packages.card.tier_withdrawn')
        )
        # Actors::SelectAiPackage#resolve_package answers :package_not_published on
        # EVERY write, rung changes included, so a live switcher here would offer
        # clicks whose only outcome is a flash error.
        expect(response.body).not_to include('ai_package_tier_key')
        # The way out is the "Eigene Konfiguration" card, which is never filtered.
        expect(response.body).to include(
          I18n.t('views.organisations.ai_settings.packages.custom.title')
        )
      end
    end

    # The ordinary case, and the guard against the notice appearing where it must
    # not: a published package inside the current filter needs no prepended card and
    # no explanation.
    it 'says nothing extra when the current package is in the grid' do
      package = publish_package(name: 'Europa')
      organisation.update_column(:ai_package_id, package.id)

      get organisation_ai_settings_path(organisation)

      expect(response.body).not_to include(outside_t('filtered_title'))
      expect(response.body).not_to include(outside_t('withdrawn_title'))
      expect(response.body).to include("data-package-card=\"#{package.id}\"")
    end
  end
end
