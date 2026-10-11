# frozen_string_literal: true

require 'rails_helper'

# The Art. 13 notice fed from the package (KI-Pakete P5): on a curated package
# it states the jurisdiction rung and processing region next to the provider,
# off one it keeps the provider-only wording. Every claim comes from ONE
# Factory.routing_disclosure call — these examples pin the rendered text, the
# factory spec pins the resolution behind it.
RSpec.describe Neo::Chat::TransparencyNoticeComponent,
               type: :component,
               legal_identity: { privacy_page_url: 'https://public.example/datenschutz' } do
  let(:organisation) do
    create(:organisation, ai_provider: 'openai', ai_access_token: 'sk-test-1234567890abcdef')
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def rendered_text
    render_inline(described_class.new(organisation: organisation)).text.squish
  end

  # A complete curated package the org can sit on: one 'fast' rung (the key a
  # blank selection resolves to) on an EU-preset-shaped chat credential.
  def put_on_package(jurisdiction: 'eu_native', processing_region: 'Frankreich',
                     chat_credential: mistral_chat, embedding_credential: nil)
    package = create(:ai_package, jurisdiction: jurisdiction, processing_region: processing_region,
                                  **{ embedding_credential: embedding_credential }.compact)
    package.tiers.create!(key: 'fast', label: 'Schnell & günstig', position: 0,
                          chat_credential: chat_credential)
    organisation.update!(ai_package: package)
    package
  end

  let(:mistral_chat) do
    create(:ai_credential, :openai_compatible, display_name: 'Mistral (EU)',
                                               name: 'Mistral FR chat', default_model: 'mistral-small-latest')
  end

  context 'without a curated package (custom semantics)' do
    it 'names the generic provider and claims no jurisdiction' do
      text = rendered_text

      expect(text).to include('OpenAI (GPT)')
      expect(text).not_to include('Verarbeitungsort')
    end

    # The physical `kind: custom` row routes off the org columns — its
    # jurisdiction must not surface as a curated claim. The row deliberately
    # CARRIES one (saveable today, nothing validates against it): with a blank
    # claim this example would be defended by blankness instead of by the
    # nil-package rule, and a disclosure leaking `organisation.ai_package`
    # would stay green (P5 review, MINOR 4 — the shared-fixture lesson).
    it 'treats a custom package row the same way' do
      custom = AiPackage.create!(kind: 'custom', name: 'Eigene Konfiguration',
                                 jurisdiction: 'eu_native', processing_region: 'Frankreich')
      organisation.update!(ai_package: custom)

      text = rendered_text

      expect(text).to include('OpenAI (GPT)')
      expect(text).not_to include('Verarbeitungsort')
    end
  end

  context 'on a curated package' do
    it 'states the credential label, the jurisdiction rung and the processing region' do
      put_on_package

      text = rendered_text

      expect(text).to include('Mistral (EU)')
      expect(text).to include('Europäisch')
      expect(text).to include('Verarbeitungsort: Frankreich.')
    end

    it 'leaves the region out when the package states none' do
      put_on_package(processing_region: nil)

      expect(rendered_text).not_to include('Verarbeitungsort')
    end

    # The rung shown is #effective_jurisdiction, not the stored column: a seat
    # corrected AFTER the package was saved (the validator blocks saving the
    # contradiction outright) must move the notice without anyone re-saving the
    # package. A component reading package.jurisdiction stays green on the happy
    # examples above and fails exactly here.
    it 'follows the derived rung when a credential fact changes after saving' do
      package = put_on_package
      package.referenced_credentials.each do |credential|
        credential.update_columns(company_domicile: AiCredential::COMPANY_DOMICILE_NON_EU, region: 'eu')
      end

      expect(rendered_text).to include('EU-Region, außereuropäischer Anbieter')
    end

    # The credentials are CLASSIFIED (both axes EU) so the derivation would
    # answer eu_native — without that, this example survives dropping the
    # self_hosted guard simply because there is nothing to derive (P5 review,
    # MINOR 4 — the shared-fixture lesson).
    it 'keeps a self_hosted claim instead of deriving it away' do
      classified = create(:ai_credential, :openai_compatible, :eu_company, region: 'eu',
                                                                           display_name: 'Selbstbetrieb', name: 'Own endpoint')
      put_on_package(jurisdiction: 'self_hosted', processing_region: nil,
                     chat_credential: classified, embedding_credential: classified)

      text = rendered_text

      expect(text).to include('Eigener Server')
      expect(text).not_to include('Europäisch')
    end

    # Legacy shape: rows saved before jurisdiction became curated-mandatory.
    # The notice's added value IS the jurisdiction — without one it must fall
    # back to the provider-only wording rather than render an empty claim.
    it 'falls back to the provider-only notice when the package claims no rung' do
      put_on_package.update_columns(jurisdiction: nil)

      text = rendered_text

      expect(text).to include('Mistral (EU)')
      expect(text).not_to include('Verarbeitungsort')
    end

    # §3.4 + Falle 2: two DIFFERENT EU companies can share provider
    # 'openai_compatible', and a Claude package needs a foreign embedding
    # credential either way — comparing labels (not provider names) is what
    # keeps the second recipient visible.
    it 'names an embedding recipient whose label differs from the chat label' do
      ionos_embed = create(:ai_credential, :openai_compatible, :embedding_only,
                           display_name: 'IONOS AI Model Hub (DE)', name: 'IONOS embed')
      put_on_package(embedding_credential: ionos_embed)

      expect(rendered_text).to include('IONOS AI Model Hub (DE)')
    end

    it 'stays silent about embeddings when both labels match' do
      # Same credential serving both lanes — one recipient, named once.
      both = create(:ai_credential, :openai_compatible, display_name: 'Mistral (EU)',
                                                        name: 'Mistral FR both')
      put_on_package(chat_credential: both, embedding_credential: both)

      expect(rendered_text).not_to include('semantische Suche')
    end

    # MAJOR 1 + pre-landing KRITISCH 1, end to end: during a staged switch the
    # search still reads the OLD active space (P4d's watcher flips it later).
    # The notice must (a) keep naming that recipient and (b) DROP the package's
    # jurisdiction line — "…(Europäisch). Verarbeitungsort: Frankreich." over
    # input that still flows to a US provider would be a false claim, not an
    # understatement.
    it 'names the still-serving search recipient and drops the jurisdiction line during a staged switch' do
      create(:ai_credential, :active, provider: 'openai', display_name: 'OpenAI (System)')
      space = create(:embedding_space, organisation: organisation)
      put_on_package
      organisation.update!(active_embedding_space_id: space.id)

      text = rendered_text

      expect(text).to include('Mistral (EU)')
      expect(text).to include('semantische Suche')
      expect(text).to include('OpenAI (System)')
      expect(text).not_to include('Europäisch')
      expect(text).not_to include('Verarbeitungsort')
    end

    # The flip restores the claim: once the active row pins the package's own
    # embedding credential, the search runs in the package's legal space again
    # and the jurisdiction line comes back.
    it 'states the jurisdiction again once the active space pins the package credential' do
      package = put_on_package
      space = create(:embedding_space, organisation: organisation,
                                       embedding_provider: 'openai_compatible',
                                       embedding_model: package.embedding_model,
                                       embedding_dims: package.embedding_dims,
                                       ai_credential_id: package.embedding_credential_id)
      organisation.update!(active_embedding_space_id: space.id)

      text = rendered_text

      expect(text).to include('Europäisch')
      expect(text).to include('Verarbeitungsort: Frankreich.')
    end
  end

  # Feinschliff P3: the note folds away. What must NOT fold away is the sentence
  # the AI Act asks for — that this is machine-generated, and by whom.
  describe 'the folded form' do
    def render_notice
      render_inline(described_class.new(organisation: organisation))
    end

    it 'keeps "AI-generated" and the provider in the summary, outside the layer' do
      summary = render_notice.css('summary').text.squish

      expect(summary).to include(I18n.t('views.organisations.chats.chat_show.ai_transparency_summary',
                                        provider: 'OpenAI (GPT)'))
      expect(summary).not_to include('Eingaben und Projektkontext werden dorthin übertragen')
    end

    it 'moves the transfer sentence and the privacy link INTO the layer' do
      layer = render_notice.css('[data-neo-ai-disclosure-target="layer"]').text.squish

      expect(layer).to include('Eingaben und Projektkontext werden dorthin übertragen')
      expect(layer).to include(I18n.t('views.organisations.chats.chat_show.ai_transparency_privacy_link'))
    end

    it 'links the configured privacy page, and nothing without one' do
      privacy_link = ->(page) { page.css('[data-neo-ai-disclosure-target="layer"] a').map { |a| a['href'] } }

      expect(privacy_link.call(render_notice)).to eq(['https://public.example/datenschutz'])
      with_legal_identity { expect(privacy_link.call(render_notice)).to be_empty }
    end

    it 'starts closed' do
      details = render_notice.css('details').first

      expect(details).to be_present
      expect(details['open']).to be_nil
    end

    # The Art. 13 half of the notice — recipient, jurisdiction, processing region,
    # and the only privacy link the chat surfaces have — must not hang on a
    # controller. This app has shipped a broken controller manifest to production
    # before. A native <details> opens with the controller absent; what the
    # controller adds (slide, Escape, click-beside) is comfort.
    it 'is a NATIVE disclosure, so the note opens without any JavaScript' do
      page = render_notice

      expect(page.css('details > summary')).to be_present
      layer = page.css('[data-neo-ai-disclosure-target="layer"]').first
      expect(layer['class']).not_to include('hidden')
      expect(page.css('details').first['data-controller']).to eq('neo-ai-disclosure')
    end

    # WCAG 2.5.3: the accessible name has to contain the visible label, or voice
    # control cannot address it. A <summary> is named by its own text, so the way
    # to keep this true is to not put an aria-label on it.
    it 'names the control by its visible text, not by an aria-label of its own' do
      summary = render_notice.css('summary').first

      expect(summary['aria-label']).to be_nil
      expect(summary.text).to include(I18n.t('views.organisations.chats.chat_show.ai_transparency_details'))
    end

    # Three surfaces render this component, and the assistant panel renders on TOP
    # of the two chat pages: a fixed id would meet itself.
    it 'carries no dom id that a second instance on the page could collide with' do
      expect(render_notice.to_html).not_to include('id=')
    end

    # A dialog promises a focus trap and a way back out. This is a disclosure, and
    # the element says so by itself.
    it 'promises no dialog semantics it does not implement' do
      html = render_notice.to_html

      expect(html).not_to include('role="dialog"')
      expect(html).not_to include('aria-modal')
    end
  end
end
