# frozen_string_literal: true

# What: Request spec for the D3 review decision — UI surfaces must not
#   ADVERTISE AI actions to orgs that have not opted in (GDPR gate).
# Type: Request spec — rendered-body gating of the legacy AI surfaces.
# Why (philosophy): Every server path already refuses politely, but a button
#   that bounces ("offer, then refuse") erodes trust in a compliance feature.
#   The ticket brings TWO surfaces: the ask-AI checkbox in the comment form
#   (show page) and the summary action, which since the header-line redesign
#   (design mock 04.09.2026) renders at the top of the LAZY timeline frame —
#   so this spec fetches both bodies, each surface asserted where it renders.
# Contract: with opt-in + valid config both surfaces render; without opt-in
#   neither does — regardless of credentials.

require 'rails_helper'

RSpec.describe 'AI surface gating on the ticket page (GDPR opt-in)', type: :request do
  let(:organisation) do
    create(:organisation, ai_provider: 'openai', ai_access_token: 'sk-test-1234567890abcdef')
  end
  let(:user) { create(:user) }
  let(:role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user, summary: nil)
    end
  end
  let!(:post_on_ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:post, ticket: ticket, user: user, organisation: organisation)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Current.user = user
  end

  after { Current.reset }

  def summary_action_path
    create_summary_organisation_project_ticket_path(organisation, project, ticket)
  end

  # The summary surface (create link, later the summary card with its
  # regenerate button) renders inside the lazy timeline frame since the
  # header-line redesign — the show page only carries the frame's src.
  def timeline_body
    get timeline_organisation_project_ticket_path(organisation, project, ticket)
    response.body
  end

  it 'renders summary button and ask-AI checkbox for an opted-in org with valid config' do
    get organisation_project_ticket_path(organisation, project, ticket)
    expect(response.body).to include('name="ask_ai"')

    expect(timeline_body).to include(summary_action_path)
  end

  # R2 key discrimination for the ask-AI checkbox (posts/_form + posts/edit, the pair
  # that must change together). Every other example here renders an org for which ALL
  # feature rows answer the same, so a checkbox keyed to any other feature passes them
  # all — measured: retyping both views to :chat left 15 examples green. Refusing
  # exactly :ask_ai_post is what makes the key visible, and the second expectation is
  # the other half: a FOREIGN row saying no must leave the checkbox alone, otherwise
  # the first half would also pass for a gate that asks nothing at all.
  describe 'the ask-AI checkbox asks its own feature key (R2)' do
    def refuse_only(feature_key)
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).with(feature_key, anything).and_return(
        Lalabase::Llm::FeatureRegistry::Availability.new(available: false, reason: :no_credential)
      )
    end

    it 'withholds the checkbox when :ask_ai_post says no' do
      refuse_only(:ask_ai_post)

      get organisation_project_ticket_path(organisation, project, ticket)
      expect(response.body).not_to include('name="ask_ai"')

      # The summary link reads its OWN row (:ticket_summary since KI-Pakete P3) —
      # it must be untouched by an :ask_ai_post refusal.
      expect(timeline_body).to include(summary_action_path)
    end

    it 'keeps the checkbox when a foreign row says no' do
      refuse_only(:meeting_summary)

      get organisation_project_ticket_path(organisation, project, ticket)

      expect(response.body).to include('name="ask_ai"')
    end

    # The SECOND door to the same checkbox. posts/edit.html.erb carries its own copy
    # of the gate ("change both together" says the comment in both files) and had NO
    # spec rendering it at all — measured: retyping only the edit view's key left all
    # 202 gate examples green, while the same mutation in posts/_form went red. A
    # comment is not a guard; this is.
    def edit_post_body
      get edit_organisation_project_ticket_post_path(organisation, project, ticket, post_on_ticket)
      response.body
    end

    it 'gates the edit form on the same key as the create form' do
      expect(edit_post_body).to include('name="ask_ai"')

      refuse_only(:ask_ai_post)
      expect(edit_post_body).not_to include('name="ask_ai"')
    end
  end

  # THIRD entry to the same action, found by the review of #391: once a summary
  # exists, a regenerate button appears — and it carried only the write-permission
  # check, no AI gate at all. Every example above renders a ticket with
  # `summary: nil`, so this branch was structurally invisible to them: the surface
  # that was ungated was exactly the one no test could reach.
  context 'when a summary already exists (regenerate button)' do
    let(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user,
                        summary: 'Bestehende Zusammenfassung.')
      end
    end

    it 'offers regeneration to an opted-in org with a usable configuration' do
      expect(timeline_body).to include(summary_action_path)
    end

    it 'withholds it without the opt-in' do
      organisation.update!(ai_enabled: false)

      expect(timeline_body).not_to include(summary_action_path)
    end

    it 'withholds it when the org is opted in but has no usable configuration' do
      organisation.update!(ai_access_token: nil)
      allow(AiCredential).to receive(:active_for_provider).and_return(nil)

      expect(timeline_body).not_to include(summary_action_path)
    end
  end

  it 'renders NEITHER surface without the opt-in — credentials alone are not enough' do
    organisation.update!(ai_enabled: false)

    get organisation_project_ticket_path(organisation, project, ticket)
    expect(response.body).not_to include('name="ask_ai"')

    expect(timeline_body).not_to include(summary_action_path)
  end

  # S2 (doc/ki_provider_reichweite_plan.md): both ticket surfaces now follow the
  # org's chat provider, because the paths behind them do — TicketSummaryService
  # (P3) and Actors::CreateAiPost (P4) route through Factory.for_chat.
  #
  # Until S2 this example asserted the OPPOSITE ("keeps BOTH hidden"), and that was
  # correct then: a gate opened above a pinned path turns "feature missing"
  # (honest) into "feature lies": button offered, ticket still shipped to OpenAI.
  # Of this pairing the file guards EXACTLY ONE direction: gate pinned back to
  # 'openai' while the routing follows the choice ⇒ red (the feature disappears
  # for orgs where it would work). The other direction (routing pinned back, gate
  # open) a request spec structurally CANNOT see: it checks the rendered body,
  # and a routing change does not change the rendering.
  # Measured (review of #391): both routings pinned back ⇒ this file stays
  # green. That direction is guarded by the unit specs (ticket_summary_service_spec /
  # create_ai_post_spec), which assert on the PROVIDER CLASS.
  context 'with an org routed to a non-OpenAI chat provider' do
    let(:organisation) do
      create(:organisation, ai_provider: 'openai_compatible',
                            ai_access_token: 'sk-mistral-own-token-1234567890',
                            ai_api_base: 'https://api.mistral.ai/v1',
                            preferred_chat_model: 'mistral-small-latest')
    end

    before { allow(AiCredential).to receive(:active_for_provider).and_return(nil) }

    it 'shows BOTH ticket surfaces — the gates ask about the provider that answers' do
      # This org has NO usable OpenAI configuration at all; the pre-S2 gates asked
      # exactly that question and withheld both surfaces.
      #
      # R2 split what used to be one precondition (ai_available_for_chat?) into the
      # two questions the two surfaces actually ask; since KI-Pakete P3 both ask the
      # registry, each for its own row — the summary button on :ticket_summary,
      # which is also the row it routes on.
      expect(organisation.ai_available_for?(:ask_ai_post)).to be_available
      expect(organisation.ai_available_for?(:ticket_summary)).to be_available
      expect(organisation.ai_available?('openai')).to be(false)

      get organisation_project_ticket_path(organisation, project, ticket)
      expect(response.body).to include('name="ask_ai"')

      expect(timeline_body).to include(summary_action_path)
    end

    it 'still withholds them once the org can no longer use its OWN provider' do
      # Gate and routing stay paired in the other direction too: no BYOK token and
      # no system credential for openai_compatible means the click would fail at
      # the seam, so the surfaces must not advertise it.
      organisation.update!(ai_access_token: nil)

      get organisation_project_ticket_path(organisation, project, ticket)
      expect(response.body).not_to include('name="ask_ai"')

      expect(timeline_body).not_to include(summary_action_path)
    end
  end
  # KI-Pakete P3 — the rendered half of the MAJOR verify finding. Its twin in
  # spec/services/ticket_summary_service_spec.rb proves the SERVICE follows the
  # utility rung; this proves the BUTTON does, which is the half a customer sees.
  #
  # Both directions, because the old gate was wrong in both: it derived the org's
  # own rung while the summary routes on the package's cheapest one.
  describe 'the summary button follows the rung the summary routes on' do
    let(:fast_credential) do
      create(:ai_credential, :openai_compatible, :eu_company, name: 'Mistral FR small',
                                                              default_model: 'mistral-small-latest',
                                                              access_token: 'mistral-fast-token-123456')
    end
    let(:thorough_credential) do
      create(:ai_credential, :openai_compatible, :eu_company, name: 'Mistral FR large',
                                                              default_model: 'mistral-large-latest',
                                                              access_token: 'mistral-large-token-1234')
    end
    let(:embedding_credential) do
      create(:ai_credential, :openai_compatible, :embedding_only, :eu_company,
             name: 'Mistral FR embed', default_model: 'mistral-embed',
             access_token: 'mistral-embed-token-123')
    end
    let(:package) do
      package = create(:ai_package, name: 'Europaeisch (zwei Stufen)',
                                    embedding_credential: embedding_credential,
                                    embedding_model: 'mistral-embed', embedding_dims: 1024)
      package.tiers.create!(key: 'fast', label: 'Schnell & guenstig', position: 0,
                            chat_credential: fast_credential)
      package.tiers.create!(key: 'thorough', label: 'Gruendlich', position: 1,
                            chat_credential: thorough_credential)
      package
    end

    # thorough, so the two rungs answer differently at all.
    before { organisation.update!(ai_package: package, ai_package_tier_key: 'thorough') }

    it 'withholds the button when the rung the summary USES is broken' do
      fast_credential.update_columns(enabled: false)

      expect(timeline_body).not_to include(summary_action_path)
    end

    it 'keeps the button when only the org rung is broken — the summary would work' do
      thorough_credential.update_columns(enabled: false)

      expect(timeline_body).to include(summary_action_path)
    end

    # Constraint from the P3 review: the summary entries in
    # _timeline_frame_content (create link / missing-key modal / regenerate)
    # must hit the per-instance memo in #ai_available_for?, not resolve once
    # per entry. Measured rather than assumed — the #368 lesson is that a memo
    # on the wrong object survives a guard spec.
    it 'resolves :ticket_summary once per render, not once per entry' do
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original

      timeline_body

      expect(Lalabase::Llm::FeatureRegistry).to have_received(:resolve).with(:ticket_summary, anything).once
    end
  end
end
