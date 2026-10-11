# frozen_string_literal: true

# What: the customer-facing KI-Paket catalogue on the org AI settings page
#   (doc/ki_pakete_plan.md §7 + §7.1) — cards, the two independent filters and
#   the "current" line.
# Type: Request spec.
# Why (philosophy): the catalogue is a COMPLIANCE surface, not decoration. Three
#   properties have to hold or the page misleads:
#   1. The strictest filter combination is the DEFAULT, so widening the legal
#      space is always a deliberate act — never the state a customer lands in.
#   2. Every rung except ① carries its restricting addendum, because ② ③ ④ are
#      exactly the fields that trigger Kapitel V (§3.1). A rung whose note went
#      missing would silently read as harmless.
#   3. An empty result explains WHICH relaxation would help — otherwise the
#      strict default looks like a defect and the customer widens both filters
#      blindly.
# Contract: published+ordered packages only; default filters show ① alone; each
#   relaxation reveals exactly its own rung; the empty state names the reachable
#   relaxation; the "current" line states the truth in both states.

require 'rails_helper'

RSpec.describe 'Organisations::AiSettings package catalogue (§7/§7.1)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user) }
  let(:admin_role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  # Without a resolvable system embedding credential the org has no current
  # vector space, and embedding_switch_for? then fails CLOSED — every card would
  # render blocked and these examples would silently stop testing the catalogue.
  # 1536 is what this credential derives, so the packages below sit on the same
  # lane and stay selectable.
  let!(:system_embedding_credential) do
    create(:ai_credential, provider: 'openai', active: true, region: 'eu', company_domicile: 'eu')
  end

  before { sign_in admin }

  # Body assertions compare against the ESCAPED form throughout. Without it an
  # assertion silently depends on whether its string happens to contain "&" or a
  # quote — "Schnell & günstig" renders as "Schnell &amp; günstig" and the naive
  # match fails for a reason that has nothing to do with the behaviour tested.
  def rendered(text)
    CGI.escapeHTML(text)
  end

  # The four fields of the §3 matrix, expressed the way the model derives them:
  # company_domicile (who) × region (where). Both credentials of a package point
  # at the same pair, so a card sits in exactly one field.
  def publish_package(name:, jurisdiction:, domicile:, region:, position: 0, dims: 1536, active: true)
    credential = create(:ai_credential, region: region, company_domicile: domicile)
    package = build(:ai_package, name: name, jurisdiction: jurisdiction, position: position,
                                 embedding_credential: credential, embedding_dims: dims, active: active)
    AiPackageTier::KEYS.each_with_index do |key, index|
      package.tiers << build(:ai_package_tier, ai_package: package, key: key,
                                               label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                                               chat_credential: credential, position: index)
    end
    package.save!
    package
  end

  def eu_native_package(name: 'Europäisch', **attrs)
    publish_package(name: name, jurisdiction: 'eu_native', domicile: 'eu', region: 'eu', **attrs)
  end

  def eu_region_foreign_provider_package(name: 'EU-Region, US-Konzern', **attrs)
    publish_package(name: name, jurisdiction: 'eu_region_foreign_provider',
                    domicile: 'non_eu', region: 'eu', **attrs)
  end

  def eu_provider_foreign_region_package(name: 'EU-Firma, US-Server', **attrs)
    publish_package(name: name, jurisdiction: 'eu_provider_foreign_region',
                    domicile: 'eu', region: 'us', **attrs)
  end

  def non_eu_package(name: 'Weltweit', **attrs)
    publish_package(name: name, jurisdiction: 'non_eu', domicile: 'non_eu', region: 'us', **attrs)
  end

  describe 'the card grid' do
    it 'renders published packages only, in catalogue order' do
      eu_native_package(name: 'Zweitrangig', position: 2)
      eu_native_package(name: 'Erstrangig', position: 1)
      eu_native_package(name: 'Entwurf', position: 0, active: false)

      get organisation_ai_settings_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Erstrangig')
      expect(response.body).to include('Zweitrangig')
      # An unpublished package is a draft, not an offering (§7b.1 wording of `active`).
      expect(response.body).not_to include('Entwurf')
      expect(response.body.index('Erstrangig')).to be < response.body.index('Zweitrangig')
      expect(response.body).not_to include('translation missing')
    end

    it 'states the package facts a card is supposed to carry' do
      package = eu_native_package
      package.update!(processing_region: 'Frankreich',
                      description: 'Verarbeitung in Frankreich durch Mistral AI, ein französisches Unternehmen.',
                      provider_note: 'Keine Trainingsnutzung, Aufbewahrung 30 Tage.')

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include('Verarbeitung in Frankreich durch Mistral AI')
      expect(response.body).to include('Frankreich')
      expect(response.body).to include('Keine Trainingsnutzung')
      # Tiers are named informatively in P2 (the switcher is P3).
      expect(response.body).to include(rendered(AiPackageTier::DEFAULT_LABELS.fetch('fast')))
      expect(response.body).to include(rendered(AiPackageTier::DEFAULT_LABELS.fetch('thorough')))
    end

    it 'offers a select button that posts to the package seam' do
      package = eu_native_package

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(select_package_organisation_ai_settings_path(organisation))
      expect(response.body).to include(package.id)
      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.card.select_button')))
    end
  end

  describe 'the two filters (§7.1)' do
    before do
      eu_native_package(name: 'Feld eins')
      eu_region_foreign_provider_package(name: 'Feld zwei')
      eu_provider_foreign_region_package(name: 'Feld drei')
      non_eu_package(name: 'Feld vier')
    end

    it 'defaults to the strictest combination — only the EU/EU field is visible' do
      get organisation_ai_settings_path(organisation)

      expect(response.body).to include('Feld eins')
      expect(response.body).not_to include('Feld zwei')
      expect(response.body).not_to include('Feld drei')
      expect(response.body).not_to include('Feld vier')
    end

    it 'reveals the non-European PROVIDER field only when the provider filter is relaxed' do
      get organisation_ai_settings_path(organisation, provider_scope: 'any')

      expect(response.body).to include('Feld eins')
      expect(response.body).to include('Feld zwei')
      # Processing is still EU-only, so the two third-country-server fields stay hidden.
      expect(response.body).not_to include('Feld drei')
      expect(response.body).not_to include('Feld vier')
    end

    it 'reveals the third-country PROCESSING field only when the processing filter is relaxed' do
      get organisation_ai_settings_path(organisation, processing_scope: 'any')

      expect(response.body).to include('Feld eins')
      expect(response.body).to include('Feld drei')
      expect(response.body).not_to include('Feld zwei')
      expect(response.body).not_to include('Feld vier')
    end

    it 'shows all four fields only when both filters are relaxed' do
      get organisation_ai_settings_path(organisation, provider_scope: 'any', processing_scope: 'any')

      expect(response.body).to include('Feld eins')
      expect(response.body).to include('Feld zwei')
      expect(response.body).to include('Feld drei')
      expect(response.body).to include('Feld vier')
    end

    # Fail closed: a widened catalogue must be the result of choosing the one
    # documented value, never of a typo, a stale bookmark or a crafted param.
    it 'treats any unknown filter value as the strict default' do
      get organisation_ai_settings_path(organisation, provider_scope: 'ANY', processing_scope: 'yes-please')

      expect(response.body).to include('Feld eins')
      expect(response.body).not_to include('Feld zwei')
      expect(response.body).not_to include('Feld vier')
    end

    it 'keeps the other filter when one is flipped' do
      get organisation_ai_settings_path(organisation, processing_scope: 'any')

      # The provider link offered on this page must carry the current processing
      # choice — otherwise every click silently resets the other axis.
      #
      # …and the open PANE too, since doc/ki_zugang_umbau_plan.md D6. Without
      # package_mode a filter click falls back to the default mode, which for an org on
      # its own configuration is `custom` — so one click on a filter would close the
      # pane the filter belongs to. Asserted on the href, not on the visible outcome:
      # the outcome only differs for one of the three states, and the href is the thing
      # that is either right or wrong for all of them.
      expect(response.body).to include(rendered(
                                         organisation_ai_settings_path(organisation, provider_scope: 'any',
                                                                                     processing_scope: 'any',
                                                                                     package_mode: 'packages',
                                                                                     anchor: 'ai_packages')
                                       ))
    end
  end

  describe 'the empty state (§7.1)' do
    it 'names the provider relaxation when that is the one that helps' do
      eu_region_foreign_provider_package

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.empty.title')))
      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.empty.hint_provider')))
    end

    it 'names the processing relaxation when that is the one that helps' do
      eu_provider_foreign_region_package

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.empty.hint_processing')))
    end

    it 'says either relaxation works when both do' do
      eu_region_foreign_provider_package
      eu_provider_foreign_region_package

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.empty.hint_both')))
    end

    # The branch that would otherwise lie: packages exist, but ONLY a double
    # relaxation reaches them. Reporting "nothing published" here would send the
    # customer to the administrator for a problem they do not have.
    it 'says both filters have to give when no single relaxation reaches a package' do
      non_eu_package

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.empty.hint_relax_both')))
      expect(response.body).not_to include(rendered(I18n.t('views.organisations.ai_settings.packages.empty.hint_none')))
    end

    it 'says nothing is published when the catalogue really is empty' do
      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.empty.hint_none')))
    end
  end

  describe 'the honest rung labels (§3)' do
    it 'renders the ③ rung with its own label instead of erasing the EU firm seat' do
      eu_provider_foreign_region_package(name: 'Drittland-Region')

      get organisation_ai_settings_path(organisation, processing_scope: 'any')

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.jurisdictions.eu_provider_foreign_region')))
      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.jurisdiction_notes.eu_provider_foreign_region')))
      expect(response.body).not_to include('translation missing')
    end

    it 'shows no restricting addendum on the one rung that triggers no transfer' do
      eu_native_package

      get organisation_ai_settings_path(organisation)

      AiPackage::JURISDICTIONS.each do |rung|
        note = I18n.t("views.organisations.ai_settings.packages.jurisdiction_notes.#{rung}", default: nil)
        expect(response.body).not_to include(note) if note.present?
      end
    end

    # THE reason the card prefers the derived rung over the stored claim, and the
    # only case in which the two can legally differ: the claim is validated once,
    # at save time, while the facts live on credential rows somebody else
    # maintains. Correcting a company seat has to move the customer-facing badge
    # WITHOUT anyone re-saving the package — otherwise the catalogue keeps
    # promising ① while the AVV facts say ②.
    #
    # Also the guard against reading `package.jurisdiction` again: with the
    # consistency validation in place, a fresh package can never contradict its
    # credentials, so this drifted row is the one shape that tells the two
    # readings apart.
    it 'shows the rung the credentials say today, not the one stored at save time' do
      package = eu_native_package(name: 'Verschobener Sitz')
      package.embedding_credential.update_columns(company_domicile: 'non_eu')

      get organisation_ai_settings_path(organisation, provider_scope: 'any')

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.jurisdictions.eu_region_foreign_provider')))
      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.jurisdiction_notes.eu_region_foreign_provider')))
      expect(response.body).not_to include(rendered(I18n.t('views.organisations.ai_settings.packages.jurisdictions.eu_native')))
    end

    # BUG (adversarial review 2026-08-02): the card prefers the derived rung
    # UNCONDITIONALLY, and #derived_jurisdiction answers the §3 MATRIX question —
    # which self_hosted is explicitly exempt from (§3.2: a third axis, not a fifth
    # field; the model's consistency validation skips it for exactly that reason).
    #
    # A self-hosted package on credentials recorded as EU/EU therefore renders as
    # ① „Europäisch", and with it loses the one sentence that answers the question
    # self-hosting is about — who the processor is. The note exists in both
    # locales and reaches nobody.
    it 'keeps the self-hosted claim on the card instead of relabelling it as a matrix rung' do
      publish_package(name: 'Eigenbetrieb', jurisdiction: 'self_hosted', domicile: 'eu', region: 'eu')

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.jurisdiction_notes.self_hosted')))
    end

    # The whole catalogue block at once. The test env does not raise on a missing
    # translation, so a key added to DE only reaches EN customers as the German
    # string via fallback — visible to nobody reviewing the DE page.
    it 'carries the same catalogue keys in DE and EN' do
      root = 'views.organisations.ai_settings.packages'
      flatten = lambda do |hash, prefix = nil|
        hash.flat_map do |key, value|
          path = [prefix, key].compact.join('.')
          value.is_a?(Hash) ? flatten.call(value, path) : [path]
        end
      end

      de = flatten.call(I18n.t(root, locale: :de, fallback: false)).sort
      en = flatten.call(I18n.t(root, locale: :en, fallback: false)).sort

      expect(de).to eq(en)
    end

    # The addendum is data (a locale key), not a branch in the view — so the
    # thing that can rot is a MISSING key, and it rots silently into "looks
    # harmless". This is the guard for that.
    it 'carries an addendum for every rung except eu_native, in DE and EN' do
      %i[de en].each do |locale|
        AiPackage::JURISDICTIONS.each do |rung|
          note = I18n.t("views.organisations.ai_settings.packages.jurisdiction_notes.#{rung}",
                        locale: locale, default: nil, fallback: false)
          label = I18n.t("views.organisations.ai_settings.packages.jurisdictions.#{rung}",
                         locale: locale, fallback: false)

          expect(label.to_s.downcase).not_to include('translation missing'),
                                             "missing #{locale} label for rung #{rung}"
          if rung == AiPackage::EU_NATIVE
            expect(note).to be_nil, "eu_native must carry no restricting addendum (#{locale})"
          else
            expect(note).to be_present, "missing #{locale} addendum for rung #{rung}"
          end
        end
      end
    end
  end

  describe 'the permanent "current" line (§7)' do
    it 'names the selected package and its plain-text sentence' do
      package = eu_native_package(name: 'Europäisch')
      package.update!(description: 'Chat und Suche werden in Frankreich von Mistral AI verarbeitet.')
      organisation.update!(ai_package: package, ai_package_tier_key: 'fast')

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(
        rendered(I18n.t('views.organisations.ai_settings.packages.current_label_package',
                        name: 'Europäisch',
                        description: 'Chat und Suche werden in Frankreich von Mistral AI verarbeitet.'))
      )
    end

    # ⚠️ WITH credentials, and that is the whole point of D7. A blank package id alone is
    # not "Eigene Konfiguration is in force", it is only "no package" — see the Z3 example
    # below for what the line says when nothing is behind it.
    it 'says "Eigene Konfiguration" while no package is selected but own credentials are' do
      organisation.update!(ai_package: nil, ai_provider: nil, ai_access_token: 'sk-live-key')

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(
        rendered(I18n.t('views.organisations.ai_settings.packages.current_label_custom'))
      )
    end

    # Z3 (D7): no package, no credentials. The line claimed a decision the organisation
    # had never made, because the schema cannot tell "never chose" from "chose custom".
    # Negative AND positive in one example on purpose: an absence assertion alone would
    # pass just as happily on a page that rendered nothing at all.
    it 'names the empty state instead of claiming a choice nobody made' do
      organisation.update!(ai_package: nil, ai_access_token: nil)

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(
        rendered(I18n.t('views.organisations.ai_settings.packages.none_configured_title'))
      )
      expect(response.body).not_to include(
        rendered(I18n.t('views.organisations.ai_settings.packages.current_label_custom'))
      )
      expect(response.body).not_to include(
        rendered(I18n.t('views.organisations.ai_settings.packages.custom.selected_badge'))
      )
    end

    # The catalogue and the truth are two different questions: a package the
    # operator has unpublished, or one the strict default filters away, must
    # still be named as what the organisation is actually running on.
    it 'still names a package the operator has unpublished' do
      package = eu_native_package(name: 'Zurückgezogen')
      organisation.update!(ai_package: package)
      package.update!(active: false)

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include('Zurückgezogen')
      # …and it is gone from the catalogue itself, which is the point.
      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.empty.hint_none')))
    end

    it 'still names a package the current filters hide' do
      package = non_eu_package(name: 'Weltweit')
      organisation.update!(ai_package: package)

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include('Weltweit')
      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.empty.hint_relax_both')))
    end
  end

  # ⚠️ A PANE since doc/ki_zugang_umbau_plan.md D6, not a card below the grid. It is
  # reached with ?package_mode=custom, which is why every example here passes the param:
  # an org on a package opens on the package way by default, and asserting the custom
  # content without opening it would fail for a reason that has nothing to do with the
  # rule under test.
  describe 'the "Eigene Konfiguration" pane' do
    # The way back out must not depend on the filters: an org on a third-country
    # package looks at an empty grid under the strict default, and that is exactly
    # the moment it needs the deselect action.
    it 'offers the way back out even when no curated package passes the filters' do
      organisation.update!(ai_package: non_eu_package)

      get organisation_ai_settings_path(organisation, package_mode: 'custom')

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.custom.select_button')))
    end

    it 'is marked as the current choice — and offers no redundant button — while it is set up and in force' do
      organisation.update!(ai_package: nil, ai_provider: nil, ai_access_token: 'sk-live-key')

      get organisation_ai_settings_path(organisation, package_mode: 'custom')

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.custom.selected_badge')))
      expect(response.body).not_to include(rendered(I18n.t('views.organisations.ai_settings.packages.custom.select_button')))
    end

    # Z3 (D7) inside the pane. The badge went by the blank package id alone, so a fresh
    # organisation read "Gewählt" over an empty access. What it needs instead is to be
    # told that nothing is stored and that nothing will work until it is.
    it 'states the absence rather than "Gewählt" when nothing is stored' do
      organisation.update!(ai_package: nil, ai_access_token: nil)

      get organisation_ai_settings_path(organisation, package_mode: 'custom')

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.custom.not_configured')))
      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.custom.not_ready_hint')))
      expect(response.body).not_to include(rendered(I18n.t('views.organisations.ai_settings.packages.custom.selected_badge')))
    end

    # The line D7 draws explicitly: no new bar on the way back. Z3 is an honest report,
    # not a lock — an org that lands there through the deselect button keeps every door
    # it had, it is only told what its state actually is.
    it 'keeps the way back clickable for an org on a package with no credentials' do
      organisation.update!(ai_package: non_eu_package, ai_access_token: nil)

      get organisation_ai_settings_path(organisation, package_mode: 'custom')

      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.custom.select_button')))
      # …and NOT the Z3 warning, which belongs to the state where this way is in force.
      expect(response.body).not_to include(rendered(I18n.t('views.organisations.ai_settings.packages.custom.not_ready_hint')))
    end
  end

  # doc/ki_zugang_umbau_plan.md D6. The page asks an either/or and now answers it as one:
  # exactly ONE way is rendered per request. Every example below asserts BOTH halves —
  # the presence of the one and the absence of the other — because a "shows the custom
  # pane" assertion alone stays green on a page that simply renders everything, which is
  # the state this rebuild exists to end.
  describe 'the two-way chooser (D6)' do
    let!(:package) { eu_native_package(name: 'Feld eins') }

    def grid_content = rendered(I18n.t('views.organisations.ai_settings.packages.filters.heading'))
    def custom_content = rendered(I18n.t('views.organisations.ai_settings.packages.custom.configure_link'))

    # The chip is asked through its data attribute, not through the word "Aktiv": that
    # word is a substring of "aktiviert", which the page says about the AI switch — the
    # first version of the negative example below was red for exactly that reason and
    # would otherwise have been "fixed" by loosening the assertion.
    def chips = response.body.scan(/data-chooser-chip="(\w+)"/).flatten

    it 'shows the package grid and NOT the custom pane on package_mode=packages' do
      get organisation_ai_settings_path(organisation, package_mode: 'packages')

      expect(response.body).to include(grid_content)
      expect(response.body).not_to include(custom_content)
    end

    it 'shows the custom pane and NOT the package grid on package_mode=custom' do
      get organisation_ai_settings_path(organisation, package_mode: 'custom')

      expect(response.body).to include(custom_content)
      expect(response.body).not_to include(grid_content)
      # The grid is not merely hidden by CSS — the cards are not rendered at all.
      expect(response.body).not_to include('Feld eins')
    end

    # Fail closed, exactly like the two filters above: a mode only changes on the one
    # documented value, never through a typo or a crafted param.
    it 'treats an unknown mode as the default rather than rendering neither pane' do
      get organisation_ai_settings_path(organisation, package_mode: 'both-please')

      expect(response.body).to include(grid_content)
      expect(response.body).not_to include(custom_content)
    end

    describe 'the default mode, when no param says otherwise' do
      it 'opens the package way for an organisation on a package' do
        organisation.update!(ai_package: package)

        get organisation_ai_settings_path(organisation)

        expect(response.body).to include(grid_content)
        expect(response.body).not_to include(custom_content)
      end

      it 'opens the custom way for an organisation running its own credentials' do
        organisation.update!(ai_package: nil, ai_provider: 'openai', ai_access_token: 'sk-live-key')

        get organisation_ai_settings_path(organisation)

        expect(response.body).to include(custom_content)
        expect(response.body).not_to include(grid_content)
      end

      # The product decision of D6, not a fallback: a fresh organisation has answered
      # nothing yet, and the curated packages are the recommended way. Opening on an
      # empty credentials pane would greet a first visit with the harder answer.
      it 'opens the package way for an organisation that has set up neither' do
        organisation.update!(ai_package: nil, ai_access_token: nil)

        get organisation_ai_settings_path(organisation)

        expect(response.body).to include(grid_content)
        expect(response.body).not_to include(custom_content)
      end
    end

    # Two signals, two carriers (D6): which way is OPEN, and which way is IN FORCE.
    # Without the second, looking at the other way would read as a switch already made.
    # Z3 (D7): no way is in force, so no tile carries the chip. The chip went by the
    # blank package id alone, which handed a fresh organisation an "Aktiv" marker on a
    # way it had never taken.
    it 'gives neither tile the chip while nothing is set up' do
      organisation.update!(ai_package: nil, ai_access_token: nil)

      get organisation_ai_settings_path(organisation)

      # Positive control alongside the absence: the tiles ARE on the page, so the missing
      # chip is a decision and not an unrendered chooser.
      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.chooser.custom_title')))
      expect(chips).to be_empty
    end

    it 'chips the custom tile once own credentials are stored' do
      organisation.update!(ai_package: nil, ai_provider: nil, ai_access_token: 'sk-live-key')

      get organisation_ai_settings_path(organisation)

      expect(chips).to eq(['custom'])
    end

    it 'chips the way that is in force, not the way that is open' do
      organisation.update!(ai_package: package)

      get organisation_ai_settings_path(organisation, package_mode: 'custom')

      # The custom PANE is open, and the chip sits on the SYSTEM tile — the way that is
      # actually in force. Exactly one chip, on the other tile: that pair is the whole
      # separation of "open" from "in force".
      expect(response.body).to include(custom_content)
      expect(chips).to eq(['packages'])
    end
  end

  # KI-Pakete P3 (§7): the Leistungsstufe is chosen INSIDE the chosen card —
  # "sichtbar untergeordnet", because it is the lighter of the two decisions and
  # must not compete with the jurisdiction choice around it.
  #
  # The location is the requirement, not a layout preference: rungs offered on
  # cards the org is not on would read as part of picking a package, i.e. as one
  # decision with four outcomes, which is exactly the multiplicative list §2
  # rejected.
  describe 'the Leistungsstufe switcher (§7, P3)' do
    let(:package) { eu_native_package(name: 'Europäisch') }

    it 'appears on the chosen card and nowhere else' do
      other = eu_native_package(name: 'Zweitpaket', position: 5)
      organisation.update!(ai_package: package, ai_package_tier_key: 'fast')

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(%(data-tier-switch="#{package.id}"))
      expect(response.body).not_to include(%(data-tier-switch="#{other.id}"))
    end

    it 'shows no switcher at all while the org is on its own configuration' do
      package

      get organisation_ai_settings_path(organisation)

      expect(response.body).not_to include('data-tier-switch')
      # …and the ladder is still NAMED, as the description of the package it is.
      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.card.tiers_heading')))
    end

    it 'marks the rung the org runs on and offers the other as a form' do
      organisation.update!(ai_package: package, ai_package_tier_key: 'fast')

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include('data-tier-active="true"')
      # The active rung is a state, the other is an action — asserted as the
      # POST parameter, because that is what makes it operable.
      expect(response.body).to include(%(name="ai_package_tier_key" value="thorough"))
      expect(response.body).not_to include(%(name="ai_package_tier_key" value="fast"))
      # BOTH parameters, and the package one is the load-bearing half: the same
      # action reads params[:ai_package_id].presence, so a switcher that dropped
      # it would post a DESELECTION — the org would land back on its own
      # configuration instead of on the other rung, with no error anywhere.
      expect(response.body).to include(%(name="ai_package_id" value="#{package.id}"))
    end

    # §2.1 made visible. Without it a customer who pays for "Gründlich" and then
    # reads a terse ticket summary concludes the switch is broken — the helper
    # paths deliberately ignore their choice, and silence about that is the worst
    # of the three options.
    it 'says that helper tasks stay on the cheapest rung regardless' do
      organisation.update!(ai_package: package, ai_package_tier_key: 'thorough')

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(
        rendered(I18n.t('views.organisations.ai_settings.packages.card.tier_utility_hint',
                        tier: AiPackageTier::DEFAULT_LABELS.fetch('fast')))
      )
    end

    # The hint NAMES a rung, so it has to name the one the request actually uses.
    # On a package without a 'fast' row that is the lowest rung it does have —
    # and the sentence asks AiPackage#utility_tier for it, the same call the
    # routing makes. A hard-coded "Schnell & günstig" would be a promise this
    # package cannot keep.
    it 'names the rung that really serves helper tasks when the package has no fast row' do
      package.tiers.find_by(key: 'fast').destroy!
      organisation.update!(ai_package: package, ai_package_tier_key: 'thorough')

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(
        rendered(I18n.t('views.organisations.ai_settings.packages.card.tier_utility_hint',
                        tier: AiPackageTier::DEFAULT_LABELS.fetch('thorough')))
      )
      expect(response.body).not_to include(rendered(AiPackageTier::DEFAULT_LABELS.fetch('fast')))
    end

    # Both contexts below need to break ONE rung, so they cannot use
    # publish_package: that helper points the embedding slot and both rungs at a
    # single credential row, and disabling it would break every rung at once (plus
    # the embedding lane). Measured, not feared — with the shared row the examples
    # passed even with the branch under test removed.
    context 'with rungs on separate credentials' do
      let(:fast_credential) { create(:ai_credential, region: 'eu', company_domicile: 'eu') }
      let(:thorough_credential) { create(:ai_credential, region: 'eu', company_domicile: 'eu') }

      let(:package) do
        embedding = create(:ai_credential, region: 'eu', company_domicile: 'eu')
        package = build(:ai_package, name: 'Europäisch', jurisdiction: 'eu_native', active: true,
                                     embedding_credential: embedding,
                                     embedding_model: 'text-embedding-3-small', embedding_dims: 1536)
        package.tiers << build(:ai_package_tier, ai_package: package, key: 'fast',
                                                 label: AiPackageTier::DEFAULT_LABELS.fetch('fast'),
                                                 chat_credential: fast_credential, position: 0)
        package.tiers << build(:ai_package_tier, ai_package: package, key: 'thorough',
                                                 label: AiPackageTier::DEFAULT_LABELS.fetch('thorough'),
                                                 chat_credential: thorough_credential, position: 1)
        package.save!
        package
      end

      # A rung whose credential an operator disabled: shown, but not offered. The
      # Actor refuses the same switch (:tier_credential_unusable), so a button here
      # would only ever produce an error message.
      context 'and the disabled one is NOT the active rung' do
        before do
          organisation.update!(ai_package: package, ai_package_tier_key: 'fast')
          thorough_credential.update_columns(enabled: false)
        end

        it 'renders it as unavailable instead of as a form' do
          get organisation_ai_settings_path(organisation)

          expect(response.body).to include('data-tier-disabled="true"')
          expect(response.body).to include(
            rendered(I18n.t('views.organisations.ai_settings.packages.card.tier_unavailable'))
          )
          expect(response.body).not_to include(%(name="ai_package_tier_key" value="thorough"))
        end

        # Counter-probe: the same rung IS offered while its credential is enabled,
        # so the assertion above is about the credential and not about the rung.
        it 'offers the same rung again once the credential is enabled' do
          thorough_credential.update_columns(enabled: true)

          get organisation_ai_settings_path(organisation)

          expect(response.body).to include(%(name="ai_package_tier_key" value="thorough"))
          expect(response.body).not_to include('data-tier-disabled="true"')
        end
      end

      # The rung the org RUNS on, broken. Branching on "is it the active one?"
      # alone painted exactly this case as healthy — on the one rung where it
      # matters most, because it is the rung every chat message uses.
      context 'and the disabled one IS the active rung' do
        before do
          organisation.update!(ai_package: package, ai_package_tier_key: 'thorough')
          thorough_credential.update_columns(enabled: false)
        end

        it 'keeps the chosen marking and shows the defect as well' do
          get organisation_ai_settings_path(organisation)

          # Both, not either: "chosen" is the true state of the column, and the
          # broken credential is the true state of the routing. The healthy fast
          # rung is what makes this observable — it renders neither marker.
          expect(response.body).to include('data-tier-active="true"')
          expect(response.body).to include('data-tier-disabled="true"')
          expect(response.body).to include(
            rendered(I18n.t('views.organisations.ai_settings.packages.card.tier_unavailable'))
          )
        end

        it 'says nothing about a defect once the credential works again' do
          thorough_credential.update_columns(enabled: true)

          get organisation_ai_settings_path(organisation)

          expect(response.body).to include('data-tier-active="true"')
          expect(response.body).not_to include('data-tier-disabled="true"')
          expect(response.body).not_to include(
            rendered(I18n.t('views.organisations.ai_settings.packages.card.tier_unavailable'))
          )
        end
      end

      # The state the §2.1 hint could lie in, and the reason it asks about
      # usability at all (review of #410): the org sits on 'Gründlich' — so its
      # CHAT keeps working, and nothing else on the page looks wrong — while the
      # rung the five helper paths actually route on is dead. The unguarded
      # sentence said "helper tasks always run on Schnell" three lines under a
      # chip reading "Zugangsdaten deaktiviert".
      context 'and the broken rung is the UTILITY one the helper paths route on' do
        before do
          organisation.update!(ai_package: package, ai_package_tier_key: 'thorough')
          fast_credential.update_columns(enabled: false)
        end

        it 'says the helper tasks are unavailable instead of promising them' do
          get organisation_ai_settings_path(organisation)

          expect(response.body).to include(
            rendered(I18n.t('views.organisations.ai_settings.packages.card.tier_utility_unavailable',
                            tier: AiPackageTier::DEFAULT_LABELS.fetch('fast')))
          )
          expect(response.body).not_to include(
            rendered(I18n.t('views.organisations.ai_settings.packages.card.tier_utility_hint',
                            tier: AiPackageTier::DEFAULT_LABELS.fetch('fast')))
          )
        end

        # The gate agrees with the screen — otherwise the warning would be
        # cosmetic. Asked of the registry row itself, which is what
        # Factory.for_feature routes on.
        it 'matches what the feature gate answers for a utility path' do
          expect(organisation.reload.ai_available_for?(:ticket_summary).available?).to be(false)
        end

        # Counter-probe: with the utility rung healthy the page carries the
        # positive sentence and no warning, so the example above is about the
        # credential and not about the org sitting on 'thorough'.
        it 'returns to the positive wording once the utility rung works again' do
          fast_credential.update_columns(enabled: true)

          get organisation_ai_settings_path(organisation)

          expect(response.body).to include(
            rendered(I18n.t('views.organisations.ai_settings.packages.card.tier_utility_hint',
                            tier: AiPackageTier::DEFAULT_LABELS.fetch('fast')))
          )
          expect(response.body).not_to include(
            rendered(I18n.t('views.organisations.ai_settings.packages.card.tier_utility_unavailable',
                            tier: AiPackageTier::DEFAULT_LABELS.fetch('fast')))
          )
        end
      end
    end
  end

  # NEU-1: the card's own "Door 1 of 2". A package whose DEFAULT rung has no
  # usable credential cannot be selected — the Actor answers
  # :tier_credential_unusable — so offering the button would produce nothing but
  # an error message.
  describe 'a package whose default rung cannot be used (P3)' do
    # Its OWN chat credential per rung, unlike publish_package above, which points
    # embedding slot and both rungs at ONE row. That shortcut is fine for the
    # jurisdiction examples but not here: disabling the shared row would take the
    # EMBEDDING slot down with it, the card would fail closed on the vector-space
    # branch instead, and this block would silently test the wrong refusal.
    let(:chat_credential) { create(:ai_credential, region: 'eu', company_domicile: 'eu') }

    let(:package) do
      embedding = create(:ai_credential, region: 'eu', company_domicile: 'eu')
      package = build(:ai_package, name: 'Europäisch', jurisdiction: 'eu_native', active: true,
                                   embedding_credential: embedding,
                                   embedding_model: 'text-embedding-3-small', embedding_dims: 1536)
      AiPackageTier::KEYS.each_with_index do |key, index|
        package.tiers << build(:ai_package_tier, ai_package: package, key: key,
                                                 label: AiPackageTier::DEFAULT_LABELS.fetch(key),
                                                 chat_credential: chat_credential, position: index)
      end
      package.save!
      package
    end

    it 'explains the refusal instead of offering the button' do
      package
      chat_credential.update_columns(enabled: false)

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(
        rendered(I18n.t('views.organisations.ai_settings.packages.card.selection_blocked'))
      )
      expect(response.body).not_to include(%(value="#{package.id}"))
    end

    # Counter-probe: the same package IS offered while the credential works, so
    # the example above is about the credential and not about the package.
    it 'offers the package again once the credential is enabled' do
      package

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(%(value="#{package.id}"))
      expect(response.body).not_to include(
        rendered(I18n.t('views.organisations.ai_settings.packages.card.selection_blocked'))
      )
    end

    # The card must judge the SAME row the Actor resolves for a blank tier_key —
    # asserted end to end rather than by reading both implementations: the card
    # withholds the button, and the very same POST hits the matching refusal.
    it 'agrees with the Actor about which rung a blank request means' do
      package
      chat_credential.update_columns(enabled: false)

      result = Actors::SelectAiPackage.call(organisation: organisation, current_user: admin,
                                            params: { ai_package_id: package.id })

      expect(result.code).to eq(:tier_credential_unusable)
      expect(package.reload).to be_selection_tier_unusable
    end

    # Both doors judge usable_for?(:chat), not enabled? alone — pinned on the
    # purpose axis, where the credential stays enabled and an enabled?-only card
    # would keep offering a selection the Actor then refuses.
    it 'withholds the button when the credential stopped serving the chat lane' do
      package
      chat_credential.update_columns(purpose: 'embedding')

      get organisation_ai_settings_path(organisation)

      expect(response.body).not_to include(%(value="#{package.id}"))
      expect(
        Actors::SelectAiPackage.call(organisation: organisation, current_user: admin,
                                     params: { ai_package_id: package.id }).code
      ).to eq(:tier_credential_unusable)
    end

    # THE case that tells #default_selection_tier and #utility_tier apart, and the
    # reason they are two methods rather than one. A package with no fast rung is
    # still perfectly usable for HELPER paths (utility_tier degrades to the lowest
    # rung it finds) but cannot be SELECTED with a blank tier_key — the Actor
    # answers :tier_not_offered. A card asking the utility question here would
    # offer a button that the Actor refuses.
    #
    # Drift, not a state the form can produce: the ladder validation keeps a
    # published package complete, so the rung is removed after the fact.
    it 'withholds the button when the default rung is missing entirely' do
      package.tiers.find_by(key: 'fast').destroy!
      package.tiers.reload

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(
        rendered(I18n.t('views.organisations.ai_settings.packages.card.selection_blocked'))
      )
      expect(response.body).not_to include(%(value="#{package.id}"))

      result = Actors::SelectAiPackage.call(organisation: organisation, current_user: admin,
                                            params: { ai_package_id: package.id })
      expect(result.code).to eq(:tier_not_offered)
      # …while the helper paths still have a rung to run on, which is exactly the
      # difference between the two questions.
      expect(package.utility_tier.key).to eq('thorough')
    end
  end

  # The page-level half of the switch block. Every other example in this file
  # depends on the org having a RESOLVABLE current vector space — the header
  # comment on system_embedding_credential says so — which makes "what happens
  # when it does not" the blind spot of the whole file rather than an edge case.
  describe 'when the organisation has no resolvable vector space at all' do
    # Factory#embedding_switch? fails CLOSED — an unresolvable lane answers "yes,
    # this moves" — so the card takes the guided route rather than the direct
    # post. Since P4b that route is the consequence dialog, not a dead end: the
    # direct button stays away, which is the part that matters here.
    it 'sends the card through the guided switch, never straight into the write' do
      eu_native_package(name: 'Europäisch')
      system_embedding_credential.update_columns(enabled: false)

      get organisation_ai_settings_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(rendered(I18n.t('views.organisations.ai_settings.packages.card.switch_notice')))
      expect(response.body).not_to include(rendered(I18n.t('views.organisations.ai_settings.packages.card.select_button')))
    end
  end

  # BUG (adversarial review 2026-08-02): AiPackage.published carries no `kind`
  # filter, so a `custom` row with active: true — the seeds row §7b.1 explicitly
  # foresees ("a physical 'custom' row … would come from db/seeds") — enters the
  # customer catalogue as a card. Three things then go wrong at once, in
  # increasing order of severity:
  #
  #   * it passes both strict filters (AiPackage#axis_of folds an empty credential
  #     list to true — see the pending example in ai_package_spec),
  #   * its select button posts an id Actors::SelectAiPackage refuses with
  #     :package_not_curated, so the card can never be chosen, and
  #   * rendering it RAISES: the card asks #embedding_switch_for?, which reaches
  #     Factory#curated_embedding_resolution with a nil credential (see the
  #     pending example in factory_spec) and dies on #enabled? for nil.
  #
  # The last one is what makes this more than cosmetic: one seeded row takes the
  # AI settings page of EVERY organisation down with a 500.
  it 'does not offer — or crash on — a published custom row' do
    AiPackage.create!(kind: 'custom', name: 'Eigene Konfiguration (Katalogzeile)', active: true)

    get organisation_ai_settings_path(organisation)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('Eigene Konfiguration (Katalogzeile)')
  end

  # T5 (doc/ki_vertragsdaten_plan.md §5, D3/D4/E1). The second and third statement
  # of the card: WHAT happens to the content, not only WHERE it is processed.
  # Both derived, never stored: a copy drifts away from the truth the moment a
  # provider changes its terms.
  describe 'the training and retention claims (T5)' do
    def assess(credential, training:, retention: AiCredentialContract::RETENTION_UNSPECIFIED, days: nil)
      create(:ai_credential_contract, ai_credential: credential, training_usage: training,
                                      retention_policy: retention, retention_days: days)
    end

    def training_label(value)
      rendered(I18n.t("views.organisations.ai_settings.packages.training_usages.#{value}"))
    end

    def training_note(value)
      rendered(I18n.t("views.organisations.ai_settings.packages.training_notes.#{value}"))
    end

    # The text of EXACTLY this card. Page-wide checks on `response.body`
    # hit something else too easily: the layout embeds an i18n JS payload
    # that contains, among other things, a raw `%{count}`. A naive assertion
    # "no %{count} in the body" is therefore permanently red, without the card
    # doing anything wrong. With a second package on the page, the same
    # blur between the cards would be added.
    def card_text(package)
      node = Nokogiri::HTML(response.body).at_css("[data-package-card='#{package.id}']")
      node&.text.to_s
    end

    # The class list of the training badge of THIS card. The existing guard only checks
    # that every value HAS a style, not that it has the right one.
    # Green and red swapped would stay green that way, and on a compliance surface
    # people read the colour before the text.
    def training_badge_classes(package, value)
      label = I18n.t("views.organisations.ai_settings.packages.training_usages.#{value}")
      spans = Nokogiri::HTML(response.body).css("[data-package-card='#{package.id}'] span")
      spans.find { |span| span.text.strip == label }&.[]('class').to_s
    end

    it 'shows the green claim and NO warning where the provider excludes training' do
      package = eu_native_package
      assess(package.embedding_credential, training: AiCredentialContract::TRAINING_EXCLUDED,
                                           retention: AiCredentialContract::RETENTION_NONE)

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(training_label(AiCredentialContract::TRAINING_EXCLUDED))
      # `excluded` is the harmless value: a warning sentence for it would be a
      # warning about the good news.
      expect(response.body).not_to include(training_note(AiCredentialContract::TRAINING_USED))
      expect(response.body).not_to include(training_note(AiCredentialContract::TRAINING_UNSPECIFIED))
      expect(response.body).not_to include('translation missing')
    end

    it 'names the training explicitly where the provider does train' do
      package = eu_native_package
      assess(package.embedding_credential, training: AiCredentialContract::TRAINING_USED)

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(training_label(AiCredentialContract::TRAINING_USED))
      expect(response.body).to include(training_note(AiCredentialContract::TRAINING_USED))
    end

    # The colour is the statement that is read first, and it was bound to its
    # value nowhere. The existing guard checks that every value HAS a
    # style; swapping green and red stayed green that way, and the card
    # showed „Training durch den Anbieter" in reassuring green.
    #
    # The colour names stand here DELIBERATELY as literals and not as a reference to
    # TRAINING_USAGE_BADGE_STYLES. Checking against the constant would be circular:
    # if you swap its values, expectation and reality move together,
    # and the spec stays green (measured, it happened exactly like that). At this
    # point the spec IS the specification: green means excluded, red means
    # trained, grey means unchecked.
    it 'paints each training answer in the colour that belongs to it' do
      calm = eu_native_package(name: 'Ruhig', position: 0)
      alarming = eu_native_package(name: 'Alarmierend', position: 1)
      unchecked = eu_native_package(name: 'Ungeprüft', position: 2)
      assess(calm.embedding_credential, training: AiCredentialContract::TRAINING_EXCLUDED)
      assess(alarming.embedding_credential, training: AiCredentialContract::TRAINING_USED)

      get organisation_ai_settings_path(organisation)

      excluded = training_badge_classes(calm, AiCredentialContract::TRAINING_EXCLUDED)
      used = training_badge_classes(alarming, AiCredentialContract::TRAINING_USED)
      unspecified = training_badge_classes(unchecked, AiCredentialContract::TRAINING_UNSPECIFIED)

      expect(excluded).to include('green')
      expect(excluded).not_to include('red')
      expect(used).to include('red')
      expect(used).not_to include('green')
      expect(unspecified).to include('gray')
      expect(unspecified).not_to include('green')
    end

    # Leaving out the grey state would be the worst option (D4): a
    # missing statement reads as an all-clear. Here without any recorded version,
    # the most common way into this state.
    it 'says so where nobody assessed the provider at all' do
      eu_native_package

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(training_label(AiCredentialContract::TRAINING_UNSPECIFIED))
      expect(response.body).to include(training_note(AiCredentialContract::TRAINING_UNSPECIFIED))
      # The third statement must also spell out the grey state. Without this
      # line only `none` and `limited` were pinned: a value-specific
      # suppression of `unspecified` would have gone unnoticed, and it is exactly
      # the unchecked state that must not stay silent.
      expect(response.body)
        .to include(rendered(I18n.t('views.organisations.ai_settings.packages.retention_notes.unspecified')))
    end

    # „Befristet" without a number is not a statement that can be written down. Before
    # the fix this state slid into a locale lookup WITHOUT `count`,
    # and a pluralised entry then returns the raw hash, which
    # `present?` takes as present. The card showed `{:one=>…, :other=>…}`.
    it 'falls back to "not assured" when a limited retention carries no number' do
      package = eu_native_package
      contract = assess(package.embedding_credential, training: AiCredentialContract::TRAINING_EXCLUDED,
                                                      retention: AiCredentialContract::RETENTION_LIMITED,
                                                      days: 30)
      # The validation requires the number for `limited`: the state is only reachable
      # by going around it, so it is also produced that way here.
      contract.update_column(:retention_days, nil)

      get organisation_ai_settings_path(organisation)

      expect(card_text(package))
        .to include(I18n.t('views.organisations.ai_settings.packages.retention_notes.unspecified'))
      # The actual failure before the fix: the raw locale hash as text.
      expect(card_text(package)).not_to include(':one=>')
    end

    # nil means „self_hosted, so no badge" on the card. An unknown
    # value returned exactly this nil through `SEVERITY.find`, so a non-self_hosted
    # card would have carried NO training statement AT ALL, and a missing
    # statement reads as an all-clear (D4).
    it 'still warns when a credential carries a value nobody knows' do
      package = eu_native_package
      contract = assess(package.embedding_credential, training: AiCredentialContract::TRAINING_EXCLUDED)
      contract.update_column(:training_usage, 'voellig_unbekannt')

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(training_label(AiCredentialContract::TRAINING_UNSPECIFIED))
      expect(response.body).to include(training_note(AiCredentialContract::TRAINING_UNSPECIFIED))
      expect(response.body).not_to include(training_label(AiCredentialContract::TRAINING_EXCLUDED))
    end

    # D3: a package is only as good as its weakest credential. Chat and
    # search sit on DIFFERENT credentials here, only one of them trains.
    it 'takes the strictest answer when the credentials disagree' do
      trainer = create(:ai_credential, region: 'eu', company_domicile: 'eu')
      package = eu_native_package
      package.tiers.first.update!(chat_credential: trainer)
      assess(package.embedding_credential, training: AiCredentialContract::TRAINING_EXCLUDED)
      assess(trainer, training: AiCredentialContract::TRAINING_USED)

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include(training_label(AiCredentialContract::TRAINING_USED))
      expect(response.body).not_to include(training_label(AiCredentialContract::TRAINING_EXCLUDED))
    end

    # Without this test the exception would be the first to silently disappear
    # in a refactoring (§7 acceptance criterion, literally). For a
    # self-operated package the question DOES NOT APPLY, it is not open: a
    # grey badge there would be a warning about nobody.
    it 'shows no training badge at all on a self-hosted package' do
      publish_package(name: 'Eigener Server', jurisdiction: AiPackage::SELF_HOSTED,
                      domicile: 'eu', region: 'eu')

      get organisation_ai_settings_path(organisation)

      expect(response.body).to include('Eigener Server')
      AiCredentialContract::TRAINING_USAGES.each do |value|
        expect(response.body).not_to include(training_label(value))
      end
    end

    it 'states plainly where nothing is stored' do
      package = eu_native_package
      assess(package.embedding_credential, training: AiCredentialContract::TRAINING_EXCLUDED,
                                           retention: AiCredentialContract::RETENTION_NONE)

      get organisation_ai_settings_path(organisation)

      expect(response.body)
        .to include(rendered(I18n.t('views.organisations.ai_settings.packages.retention_notes.none')))
    end

    # The HIGHEST number of days wins: naming the smaller one would be the prettier
    # and therefore false statement. Two credentials with unequal periods.
    it 'names the longest storage period of the involved credentials' do
      slow = create(:ai_credential, region: 'eu', company_domicile: 'eu')
      package = eu_native_package
      package.tiers.first.update!(chat_credential: slow)
      assess(package.embedding_credential, training: AiCredentialContract::TRAINING_EXCLUDED,
                                           retention: AiCredentialContract::RETENTION_LIMITED, days: 7)
      assess(slow, training: AiCredentialContract::TRAINING_EXCLUDED,
                   retention: AiCredentialContract::RETENTION_LIMITED, days: 30)

      get organisation_ai_settings_path(organisation)

      expect(response.body)
        .to include(rendered(I18n.t('views.organisations.ai_settings.packages.retention_notes.limited', count: 30)))
      expect(response.body)
        .not_to include(rendered(I18n.t('views.organisations.ai_settings.packages.retention_notes.limited', count: 7)))
    end

    # Completeness as a data guard, not as a branch in the template: a newly
    # added value without a note would otherwise fall into the harmless-looking state.
    # `I18n.backend.translations.dig` instead of `I18n.exists?`, because the en→de fallback
    # reports every missing English translation as present.
    describe 'completeness of the claim vocabulary' do
      def entry(locale, *path)
        I18n.backend.translations.dig(locale, :views, :organisations, :ai_settings, :packages, *path)
      end

      %i[de en].each do |locale|
        it "has a label for every training value in #{locale}" do
          AiCredentialContract::TRAINING_USAGES.each do |value|
            expect(entry(locale, :training_usages, value.to_sym)).to be_present,
                                                                     "#{locale}: training_usages.#{value} fehlt"
          end
        end

        it "has a warning for every training value but the harmless one in #{locale}" do
          (AiCredentialContract::TRAINING_USAGES - [AiCredentialContract::TRAINING_EXCLUDED]).each do |value|
            expect(entry(locale, :training_notes, value.to_sym)).to be_present,
                                                                    "#{locale}: training_notes.#{value} fehlt"
          end
        end

        # Here the good value ALSO carries a sentence: retention has no
        # badge of its own, without a sentence it would stay invisible. Hence ALL values.
        it "has a sentence for every retention value in #{locale}" do
          AiCredentialContract::RETENTION_POLICIES.each do |value|
            expect(entry(locale, :retention_notes, value.to_sym)).to be_present,
                                                                     "#{locale}: retention_notes.#{value} fehlt"
          end
        end
      end

      it 'pairs every training value with a badge style' do
        expect(AiPackage::TRAINING_USAGE_BADGE_STYLES.keys)
          .to match_array(AiCredentialContract::TRAINING_USAGES)
      end
    end

    # The derivation runs package → credentials → recorded version. `contract_on`
    # only filters in memory when the association is loaded: without
    # `with_customer_claims` every card is one query per credential. Prosopite
    # scans globally here (spec/support/prosopite.rb), so the test only needs
    # enough cards for an N+1 to show up as a pattern at all.
    it 'reads the claims of many cards without a query per card' do
      3.times do |index|
        package = eu_native_package(name: "Paket #{index}", position: index)
        assess(package.embedding_credential, training: AiCredentialContract::TRAINING_EXCLUDED,
                                             retention: AiCredentialContract::RETENTION_LIMITED, days: 30)
      end

      get organisation_ai_settings_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(training_label(AiCredentialContract::TRAINING_EXCLUDED))
    end
  end

  describe 'as a plain member' do
    let(:member) { create(:user) }
    let(:member_role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation) } }

    let!(:member_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, role: member_role, active: true)
      end
    end

    # The catalogue names credentials, endpoints and jurisdictions — the same
    # operator-level information the rest of this page is admin-only for. It is
    # the POLICY that keeps it out of a member's hands, not the absence of a link.
    it 'never reaches the catalogue at all' do
      eu_native_package(name: 'Europäisch')
      sign_in member

      get organisation_ai_settings_path(organisation)

      expect(response).not_to have_http_status(:ok)
      expect(response.body).not_to include('Europäisch')
    end
  end
end
