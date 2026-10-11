# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Organisations::TimeSessionGroups', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:time_session_group) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session_group, organisation: organisation, creator: user)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Current.user = user
  end

  after { Current.reset }

  describe 'GET /org/:organisation_id/time_session_groups/:id (show)' do
    it 'redirects to chronological view by default' do
      get organisation_time_session_group_path(organisation, time_session_group)

      expect(response).to redirect_to(chronological_organisation_time_session_group_path(organisation, time_session_group))
    end
  end

  describe 'GET /org/:organisation_id/time_session_groups/:id/chronological' do
    let(:project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end
    let!(:time_sessions) do
      ActsAsTenant.with_tenant(organisation) do
        create_list(:time_session, 3,
                    organisation: organisation,
                    time_session_group: time_session_group,
                    project: project,
                    creator: user)
      end
    end

    it 'renders the chronological view successfully' do
      get chronological_organisation_time_session_group_path(organisation, time_session_group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Zeiten in dieser Abrechnung')
      expect(response.body).to include('chronologisch')
    end

    it 'loads time sessions and activities' do
      get chronological_organisation_time_session_group_path(organisation, time_session_group)

      expect(assigns(:time_sessions)).to match_array(time_sessions)
      expect(assigns(:activities)).to be_present
    end

    it 'displays time sessions in chronological table' do
      get chronological_organisation_time_session_group_path(organisation, time_session_group)

      expect(response.body).to include('Dauer')
      expect(response.body).to include('Datum')
      expect(response.body).to include('ID')
      expect(response.body).to include('Bezug')
      expect(response.body).to include('Benutzer')
    end

    # D1 of the detail alignment (doc/abrechnung_detail_angleichung_plan.md):
    # the head speaks the times language - the name is the headline, the figures
    # come as one flat line, and no key may be missing (the P2 lesson: a green
    # spec over a page full of "translation missing" markers).
    it 'shows the billing name and the key-figure line without missing keys' do
      get chronological_organisation_time_session_group_path(organisation, time_session_group)

      expect(response.body).to include(time_session_group.name)
      expect(response.body).to include('Zeitraum')
      expect(response.body).to include('Zur Rechnung geben')
      expect(response.body).not_to include('Abrechnung Details')
      expect(response.body).not_to include('translation_missing')
    end

    # The locale guard cannot see a missing EN key (fallbacks = [:de] renders
    # the German silently), so the pairing is pinned here.
    it 'carries every show_header key in both locales' do
      %w[back_to_list bill_button figure_duration figure_status figure_period
         figure_scope figure_projects figure_invoice times_count].each do |key|
        %i[de en].each do |locale|
          expect(I18n.exists?("views.organisations.time_session_groups.show_header.#{key}", locale))
            .to be(true), "missing #{locale} key: #{key}"
        end
      end
    end
  end

  describe 'GET /org/:organisation_id/time_session_groups/:id/aggregated' do
    let(:project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end
    let(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation)
      end
    end
    let!(:time_sessions) do
      ActsAsTenant.with_tenant(organisation) do
        create_list(:time_session, 3,
                    organisation: organisation,
                    time_session_group: time_session_group,
                    project: project,
                    ticket: ticket,
                    creator: user)
      end
    end

    it 'renders the aggregated view successfully' do
      get aggregated_organisation_time_session_group_path(organisation, time_session_group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Zeiten in dieser Abrechnung')
      expect(response.body).to include('nach Bezug')
    end

    it 'loads time sessions and groups by subject' do
      get aggregated_organisation_time_session_group_path(organisation, time_session_group)

      expect(assigns(:time_sessions)).to match_array(time_sessions)
      expect(assigns(:sessions_by_subject)).to be_present
      expect(assigns(:sessions_by_subject).keys).to include(ticket)
    end

    it 'displays aggregated table headers' do
      get aggregated_organisation_time_session_group_path(organisation, time_session_group)

      expect(response.body).to include('Bezug')
      expect(response.body).to include('Anzahl')
      expect(response.body).to include('Dauer')
      expect(response.body).to include('Zeitraum')
      expect(response.body).to include(project.name)
    end

    # The reported bug: time booked on a meeting reached the billing as a row
    # labelled "Ohne Ticket" — no title, no link, nothing the reader could tie the
    # hours to. Meetings became bookable subjects in Gespräche Slice 2; these
    # views were never taught about them.
    context 'with time booked on meetings' do
      let(:meeting) do
        ActsAsTenant.with_tenant(organisation) do
          create(:meeting, project: project, organisation: organisation, creator: user, title: 'Kickoff Kunde')
        end
      end
      let(:other_meeting) do
        ActsAsTenant.with_tenant(organisation) do
          create(:meeting, project: project, organisation: organisation, creator: user, title: 'Retro Q3')
        end
      end
      let!(:meeting_sessions) do
        ActsAsTenant.with_tenant(organisation) do
          [create(:time_session, organisation: organisation, time_session_group: time_session_group,
                                 project: project, meeting: meeting, creator: user, duration: 60),
           create(:time_session, organisation: organisation, time_session_group: time_session_group,
                                 project: project, meeting: other_meeting, creator: user, duration: 30)]
        end
      end

      it 'names each meeting instead of rendering it as an unlabelled row' do
        get aggregated_organisation_time_session_group_path(organisation, time_session_group)

        expect(response.body).to include('Kickoff Kunde')
        expect(response.body).to include('Retro Q3')
        expect(response.body).not_to include('Ohne Bezug')
      end

      it 'gives every meeting its own row rather than summing them into one' do
        get aggregated_organisation_time_session_group_path(organisation, time_session_group)

        expect(assigns(:sessions_by_subject).keys).to include(meeting, other_meeting)
        expect(assigns(:sessions_by_subject)[meeting].map(&:duration)).to eq([60])
        expect(assigns(:sessions_by_subject)[other_meeting].map(&:duration)).to eq([30])
      end
    end
  end

  describe 'GET /org/:organisation_id/time_session_groups/:id/customer_export' do
    let(:project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end
    let!(:time_session_with_description) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session,
               organisation: organisation,
               time_session_group: time_session_group,
               project: project,
               creator: user,
               customer_description: 'Customer-friendly description')
      end
    end
    let!(:time_session_without_description) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session,
               organisation: organisation,
               time_session_group: time_session_group,
               project: project,
               creator: user,
               customer_description: nil)
      end
    end

    it 'renders the customer export view successfully' do
      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Zeiten in dieser Abrechnung')
      expect(response.body).to include('Kundenexport')
    end

    it 'loads time sessions and counts sessions with descriptions' do
      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      expect(assigns(:time_sessions).count).to eq(2)
      expect(assigns(:sessions_with_description)).to eq(1)
    end

    it 'displays customer description header and export buttons' do
      # Generation buttons are AI surfaces: since the GDPR opt-in (audit
      # 2026-07-03) they render only for orgs with ai_available? — opt-in
      # (factory default) plus a usable OpenAI configuration, provided here.
      organisation.update!(ai_provider: 'openai', ai_access_token: 'sk-test-1234567890abcdef')

      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      expect(response.body).to include('Kundenbeschreibungen')
      expect(response.body).to include('Beschreibungen erstellen')
      expect(response.body).to include('Excel-Export')
    end

    it 'hides the generation buttons without the AI opt-in — Excel export stays' do
      organisation.update!(ai_enabled: false,
                           ai_provider: 'openai', ai_access_token: 'sk-test-1234567890abcdef')

      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      expect(response.body).not_to include('Beschreibungen erstellen')
      expect(response.body).to include('Excel-Export') # non-AI action unaffected
    end

    # R3 (doc/ai_feature_registry_plan.md): :customer_description is the ONE
    # technically justified pin — gpt-5-nano is a reasoning model, reasoning_effort
    # travels via provider_options and OpenAiProvider switches to the
    # max_completion_tokens dialect for it. The feature is switched OFF for orgs
    # routing elsewhere and SAYS SO, rather than silently sending their time entries
    # to OpenAI.
    #
    # The button is now rendered DISABLED rather than omitted (R3 behaviour change):
    # the action stays where the user looks for it and the sentence beside it answers
    # "why can I not click this?". The discriminator is therefore the POST path, not
    # the label — a disabled ButtonComponent renders no href and no form.
    def generate_action_offered?
      response.body.include?(
        generate_customer_descriptions_organisation_time_session_group_path(organisation, time_session_group)
      )
    end

    it 'disables the generation button AND explains why, for an org on another chat provider' do
      # NO stub on active_for_provider here, deliberately: an ACTIVE OpenAI system
      # credential must exist for this example to test anything. Stubbing it away
      # would make ai_available?('openai') false too, and the example would pass
      # against a gate that merely asked "does a credential exist" — it is exactly
      # the strictness of the pin (the org must ROUTE there) that this is about.
      create(:ai_credential, :active, provider: 'openai')
      organisation.update!(ai_enabled: true, ai_provider: 'openai_compatible',
                           ai_access_token: 'sk-mistral-own-token-1234567890',
                           ai_api_base: 'https://api.mistral.ai/v1',
                           preferred_chat_model: 'mistral-small-latest')
      # Usable for chat, and OpenAI would be usable too — the org just doesn't route
      # there. :chat is the right key for that claim: it is about the org's chat lane
      # in general, not about the pinned feature whose button is dead.
      expect(organisation.ai_available_for?(:chat)).to be_available
      expect(organisation.ai_available?('openai')).to be(true)

      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      expect(generate_action_offered?).to be(false)
      expect(response.body).to include('Beschreibungen erstellen') # …but visibly, as a dead button
      expect(response.body).to include('Excel-Export') # non-AI action unaffected
      # The hint names BOTH providers — without the second half the admin does not
      # know what the org is currently on, and a dead button explains nothing.
      expect(response.body).to include(CGI.escapeHTML(AiCredential.provider_display_names.fetch('openai')))
      expect(response.body).to include(CGI.escapeHTML(AiCredential.provider_display_names.fetch('openai_compatible')))
    end

    # The button is dead for exactly these orgs, so a direct POST is the ONLY real
    # way to reach the actor guard — which makes this the only place where the chain
    # guard → result.errors.first → flash is observable end to end. Without it,
    # dropping :feature_unavailable from generate_error_message stays green and the
    # user gets the generic "Fehler beim Erstellen" instead of the explanation.
    it 'answers a direct POST with the pinned-provider explanation, not the generic error' do
      create(:ai_credential, :active, provider: 'openai')
      organisation.update!(ai_enabled: true, ai_provider: 'openai_compatible',
                           ai_access_token: 'sk-mistral-own-token-1234567890',
                           ai_api_base: 'https://api.mistral.ai/v1',
                           preferred_chat_model: 'mistral-small-latest')

      post generate_customer_descriptions_organisation_time_session_group_path(organisation, time_session_group)

      expect(flash[:alert]).to eq(
        I18n.t('shared.ai.unavailable.pinned_elsewhere',
               provider: AiCredential.provider_display_names.fetch('openai', 'openai'),
               current: AiCredential.provider_display_names.fetch('openai_compatible', 'openai_compatible'))
      )
      expect(flash[:alert]).not_to eq(I18n.t('flash.time_session_groups.descriptions_error'))
    end

    # R3-B3 (adversarial review): when the bulk twin refuses AFTER the actor guard
    # passed (a config change losing the race), the run ends 0/0/0 with the reason
    # only in results[:errors] — which build_flash_message used to throw away,
    # rendering the generic nothing-happened line. The recorded sentence must win.
    it 'surfaces the bulk refusal reason instead of the generic no-descriptions line' do
      create(:ai_credential, :active, provider: 'openai')
      organisation.update!(ai_enabled: true, ai_provider: 'openai',
                           ai_access_token: 'sk-org-own-1234567890abcdef')
      refusal = 'Für OpenAI (GPT) ist kein nutzbarer Zugang hinterlegt.'
      allow_any_instance_of(BulkCustomerDescriptionGenerator).to receive(:generate_all)
        .and_return({ success: 0, failed: 0, skipped: 0, errors: [refusal] })

      post generate_customer_descriptions_organisation_time_session_group_path(organisation, time_session_group)

      expect(flash.to_hash.values.join).to include(refusal)
      expect(flash.to_hash.values.join).not_to include(I18n.t('flash.time_session_groups.no_descriptions_created'))
    end

    # THE key-scoped mutation guard (R2's lesson, sharpened by the #402 review): all
    # unpinned chat rows answer alike today, so a WRONG feature key at a call site is
    # invisible in production — and a blanket stub on ai_available_for? is invisible
    # in the spec too, because it answers for every key. Both stubs below carry
    # `with(...)`: the view must read :customer_description and nothing else.
    def stub_feature(key, available, reason: nil)
      # Baseline: an org that CAN use the feature, so the stub is the only variable.
      # Without it the factory default (opted in, no credential) answers :no_credential
      # for every key and the "neighbouring key" example would pass for the wrong reason.
      organisation.update!(ai_enabled: true, ai_provider: 'openai',
                           ai_access_token: 'sk-org-own-1234567890abcdef')
      allow_any_instance_of(Organisation).to receive(:ai_available_for?).and_call_original
      allow_any_instance_of(Organisation).to receive(:ai_available_for?).with(key).and_return(
        Lalabase::Llm::FeatureRegistry::Availability.new(available: available, reason: reason,
                                                         required_provider: 'openai')
      )
    end

    it 'offers the generation button when its own feature key says yes' do
      stub_feature(:customer_description, true)

      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      expect(generate_action_offered?).to be(true)
    end

    it 'reads :customer_description — refusing a NEIGHBOURING key changes nothing' do
      stub_feature(:chat, false, reason: :pinned_elsewhere)

      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      expect(generate_action_offered?).to be(true)
    end

    it 'kills the button when :customer_description alone is refused' do
      stub_feature(:customer_description, false, reason: :pinned_elsewhere)

      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      expect(generate_action_offered?).to be(false)
      expect(response.body).to include(CGI.escapeHTML(I18n.t(
                                                        'shared.ai.unavailable.pinned_elsewhere',
                                                        provider: AiCredential.provider_display_names.fetch('openai'),
                                                        current: AiCredential.provider_display_names.fetch('openai')
                                                      )))
    end

    # "No POST path in the body" is necessary but NOT sufficient for this branch, and
    # measured: dropping `disabled: true` from the component call leaves the whole
    # suite green, while the page then shows a fully styled, live-LOOKING button that
    # swallows every click (no href, no form, no JS handler behind it). That is the
    # "feature lies" failure mode E1 decided against, one keyword away — so the dead
    # button is asserted as dead, not merely as unwired.
    it 'renders the refusal as a genuinely dead button, not a live-looking one' do
      stub_feature(:customer_description, false, reason: :pinned_elsewhere)

      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      buttons = Nokogiri::HTML(response.body).css('button')
      button = buttons.find { |node| node.text.include?('Beschreibungen erstellen') }
      # nil here also catches a re-added url:, which would turn the component into an
      # <a> — visually identical, and clickable.
      expect(button).to be_present
      expect(button.attributes).to have_key('disabled')
      # …and nothing around it submits either: button_to would have wrapped it in a
      # form, which fires regardless of how the button itself looks.
      expect(button.ancestors('form')).to be_empty
    end

    # R3-B1 (adversarial review): :no_credential gets the SAME disabled-button
    # treatment as :pinned_elsewhere — unavailable_hint carries a correct,
    # actionable sentence for it, so silence would leave an admin with an
    # expired key staring at nothing exactly where they look. Only :ai_disabled
    # stays silent here (flat R4 rollout).
    it 'shows the disabled button WITH the no-credential hint' do
      stub_feature(:customer_description, false, reason: :no_credential)

      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      doc = Nokogiri::HTML(response.body)
      button = doc.css('button').find { |node| node.text.include?('Beschreibungen erstellen') }
      expect(button).to be_present
      expect(button.attributes).to have_key('disabled')
      # The reason is wired to the button for assistive tech (R3-B5): the
      # disabled button is not focusable, but reading mode follows the reference.
      expect(button['aria-describedby']).to eq('customer-descriptions-unavailable-hint')
      hint = doc.at_css('#customer-descriptions-unavailable-hint')
      expect(hint.text).to include(
        I18n.t('shared.ai.unavailable.no_credential',
               provider: AiCredential.provider_display_names.fetch('openai'),
               current: AiCredential.provider_display_names.fetch('openai'))
      )
    end

    # The no-credential copy must name the PINNED provider, not the pinning story —
    # an org that already routes to openai and merely lacks a key gets the honest
    # "no usable access for OpenAI" sentence, never the pinned_elsewhere text.
    it 'explains a missing credential without the pinning story when the org is on the pinned provider' do
      allow(AiCredential).to receive(:active_for_provider).and_return(nil)
      organisation.update!(ai_enabled: true, ai_provider: 'openai', ai_access_token: nil)

      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      expect(response.body).to include(
        CGI.escapeHTML(I18n.t('shared.ai.unavailable.no_credential',
                              provider: AiCredential.provider_display_names.fetch('openai'),
                              current: AiCredential.provider_display_names.fetch('openai')))
      )
      expect(response.body).not_to include(CGI.escapeHTML(AiCredential.provider_display_names.fetch('openai_compatible')))
    end

    it 'displays time sessions with and without customer descriptions' do
      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      expect(response.body).to include('Customer-friendly description')
      expect(response.body).to include('Keine Kundenbeschreibung')
    end
  end

  # This CSV is the one artefact that leaves the building: it goes to the customer
  # as the annex to an invoice. It used to carry Ticket-Nr./Ticket-Name columns
  # filled from .ticket alone, so every hour booked on a meeting arrived as a row
  # with an empty subject — a charge the customer cannot account for.
  describe 'GET /org/:organisation_id/time_session_groups/:id/export_customer_descriptions' do
    let(:project) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end
    let(:ticket) do
      ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation, title: 'Listenansicht') }
    end
    let(:meeting) do
      ActsAsTenant.with_tenant(organisation) do
        create(:meeting, project: project, organisation: organisation, creator: user, title: 'Kickoff Kunde')
      end
    end

    def export_rows
      get export_customer_descriptions_organisation_time_session_group_path(organisation, time_session_group)
      CSV.parse(response.body.delete_prefix("\xEF\xBB\xBF"), col_sep: ';', headers: true)
    end

    it 'names the subject columns "Bezug", not "Ticket"' do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, time_session_group: time_session_group,
                              project: project, ticket: ticket, creator: user)
      end

      expect(export_rows.headers).to include('Bezug-Nr.', 'Bezug')
      expect(export_rows.headers).not_to include('Ticket-Nr.', 'Ticket-Name')
    end

    it 'carries the meeting title into the Bezug column and leaves the number empty' do
      # The regression: reading .ticket only produced two blank cells here.
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, time_session_group: time_session_group,
                              project: project, meeting: meeting, creator: user)
      end

      row = export_rows.first

      expect(row['Bezug']).to eq('Kickoff Kunde')
      expect(row['Bezug-Nr.']).to be_nil # only tickets carry a number — none is invented
    end

    it 'still exports a ticket with its number and title' do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, time_session_group: time_session_group,
                              project: project, ticket: ticket, creator: user)
      end

      row = export_rows.first

      expect(row['Bezug-Nr.']).to eq(ticket.number.to_s)
      expect(row['Bezug']).to eq('Listenansicht')
    end

    it 'leaves both subject columns empty for a session booked on the project alone' do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, time_session_group: time_session_group,
                              project: project, creator: user)
      end

      row = export_rows.first

      expect(row['Bezug-Nr.']).to be_nil
      expect(row['Bezug']).to be_nil
    end
  end

  # The view toggle marks its active entry with aria-current="page" (see
  # time_session_groups/_navigation). These assertions deliberately target that semantic
  # attribute rather than Tailwind classes: the earlier class-regex version silently rotted
  # when the Warm-Editorial token change swapped bg-white/text-gray-900 for the cream scale,
  # and a nav that renders no active state at all must fail here.
  describe 'Navigation active state' do
    def page_doc
      Capybara.string(response.body)
    end

    # The view toggle's active link only: the times-area subnav above the header
    # marks its own active tab with aria-current too (shared/_times_subnav).
    def active_nav_link
      subnav_label = I18n.t('navigation.times_tabs.label')
      Nokogiri::HTML(response.body).css("a[aria-current='page']").reject do |link|
        link.ancestors('nav').any? { |nav| nav['aria-label'] == subnav_label }
      end
    end

    it 'shows chronological as active in chronological view' do
      get chronological_organisation_time_session_group_path(organisation, time_session_group)

      expect(active_nav_link.size).to eq(1)
      expect(active_nav_link.first['href'])
        .to eq(chronological_organisation_time_session_group_path(organisation, time_session_group))
    end

    it 'shows aggregated as active in aggregated view' do
      get aggregated_organisation_time_session_group_path(organisation, time_session_group)

      expect(active_nav_link.size).to eq(1)
      expect(active_nav_link.first['href'])
        .to eq(aggregated_organisation_time_session_group_path(organisation, time_session_group))
    end

    it 'shows customer export as active in customer export view' do
      get customer_export_organisation_time_session_group_path(organisation, time_session_group)

      expect(active_nav_link.size).to eq(1)
      expect(active_nav_link.first['href'])
        .to eq(customer_export_organisation_time_session_group_path(organisation, time_session_group))
    end

    # Guards the inverse of the three cases above: the two non-active entries must stay
    # unmarked, so a view that tags every link 'page' cannot pass.
    it 'leaves the two inactive views unmarked' do
      get aggregated_organisation_time_session_group_path(organisation, time_session_group)

      %i[chronological customer_export].each do |inactive_view|
        path = send(:"#{inactive_view}_organisation_time_session_group_path", organisation, time_session_group)
        expect(page_doc).to have_no_css("a[href='#{path}'][aria-current]", visible: :all)
      end
    end
  end

  describe 'PATCH /org/:organisation_id/time_session_groups/:id (update)' do
    let(:project) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end

    describe '[P1] absent :billed key (R1, plan §9.8-4)' do
      let(:billed_group) do
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session_group, :billed, organisation: organisation, creator: user)
        end
      end
      let!(:billed_session) do
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session,
                 organisation: organisation, project: project, creator: user,
                 time_session_group: billed_group, billed: true,
                 invoice_number: billed_group.invoice_number)
        end
      end

      # Regression [P1] (plan §9.8-4): a PATCH whose params carry NO :billed key
      # (hand-built request, future partial form) must not touch the billing
      # state. Before the fix, cast(nil) != was_billed routed into
      # mark_as_unbilled and wiped the invoice number on the group AND all its
      # sessions.
      it 'does not unbill the group when the :billed key is absent' do
        patch organisation_time_session_group_path(organisation, billed_group),
              params: { time_session_group: { name: 'Umbenannt' } }

        expect(response).to redirect_to(organisation_time_session_groups_path(organisation))
        billed_group.reload
        expect(billed_group.billed).to be(true)
        expect(billed_group.invoice_number).to be_present
        expect(billed_group.name).to eq('Umbenannt')
        billed_session.reload
        expect(billed_session.billed).to be(true)
        expect(billed_session.invoice_number).to be_present
      end
    end

    describe 'billing atomicity (R2, plan §9.3-3)' do
      let!(:open_session) do
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session,
                 organisation: organisation, project: project, creator: user,
                 time_session_group: time_session_group)
        end
      end

      # Regression (plan §9.3-3): before the actor, the billing service
      # committed its own transaction, the remaining-fields update failed
      # silently (return value ignored) and the user still saw the success
      # notice on a half-updated group.
      it 'keeps group and sessions untouched when the invoice number is missing' do
        patch billing_status_organisation_time_session_group_path(organisation, time_session_group),
              params: { time_session_group: { billed: '1', invoice_number: '' } }

        expect(response).to have_http_status(:unprocessable_content)
        time_session_group.reload
        expect(time_session_group.billed).to be(false)
        expect(time_session_group.invoice_number).to be_nil
        expect(open_session.reload.billed).to be(false)
        expect(flash[:notice]).to be_nil
      end
    end

    # Coverage gaps (plan §6.4): #update had NO request coverage before T2.
    describe 'happy paths' do
      let!(:open_session) do
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session,
                 organisation: organisation, project: project, creator: user,
                 time_session_group: time_session_group)
        end
      end

      it 'marks the group and its sessions as billed' do
        patch billing_status_organisation_time_session_group_path(organisation, time_session_group),
              params: { time_session_group: { billed: '1', invoice_number: 'INV-100' } }

        expect(response).to redirect_to(organisation_time_session_group_path(organisation, time_session_group))
        expect(flash[:notice]).to eq(I18n.t('flash.time_session_groups.updated'))
        time_session_group.reload
        expect(time_session_group.billed).to be(true)
        expect(time_session_group.invoice_number).to eq('INV-100')
        open_session.reload
        expect(open_session.billed).to be(true)
        expect(open_session.invoice_number).to eq('INV-100')
      end

      it 'unbills a billed group on an explicit billed: 0' do
        billed_group = ActsAsTenant.with_tenant(organisation) do
          create(:time_session_group, :billed, organisation: organisation, creator: user)
        end

        patch billing_status_organisation_time_session_group_path(organisation, billed_group),
              params: { time_session_group: { billed: '0' } }

        expect(response).to redirect_to(organisation_time_session_group_path(organisation, billed_group))
        billed_group.reload
        expect(billed_group.billed).to be(false)
        expect(billed_group.invoice_number).to be_nil
      end

      it 'updates plain fields without touching the billing state' do
        patch organisation_time_session_group_path(organisation, time_session_group),
              params: { time_session_group: { name: 'Sprint Juli', billed: '0' } }

        expect(response).to redirect_to(organisation_time_session_groups_path(organisation))
        time_session_group.reload
        expect(time_session_group.name).to eq('Sprint Juli')
        expect(time_session_group.billed).to be(false)
        expect(open_session.reload.billed).to be(false)
      end
    end

    # In dev/test the actor re-raises unexpected errors, so this branch only
    # ever runs in production — stub the actor to pin it: raw exception text
    # (e.g. a RecordNotUnique message with full SQL) must never reach the form.
    describe 'internal_error mapping (production-only failure branch)' do
      it 'renders a generic message instead of the raw exception text' do
        failure = Actors::BaseActor::Result.new(
          success: false, errors: ['PG::UniqueViolation: duplicate key value violates unique constraint'],
          code: :internal_error
        )
        allow(Actors::UpdateTimeSessionGroupBilling).to receive(:call).and_return(failure)

        patch organisation_time_session_group_path(organisation, time_session_group),
              params: { time_session_group: { name: 'X' } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.time_session_groups.update_error'))
        expect(response.body).not_to include('PG::UniqueViolation')
      end
    end

    # Pins the authorize callback wiring on #update itself (the policy spec only
    # covers the policy): a plain member must not be able to unbill a group —
    # mirror of the denied test for generate_customer_descriptions below.
    describe 'authorization' do
      let(:plain_user) { create(:user) }
      let(:plain_role) { create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}") }
      let!(:plain_membership) do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: plain_user, organisation: organisation, role: plain_role, active: true)
        end
      end
      let(:billed_group) do
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session_group, :billed, organisation: organisation, creator: user)
        end
      end

      it 'denies a plain member who is not the creator from unbilling' do
        sign_out user
        sign_in plain_user

        patch billing_status_organisation_time_session_group_path(organisation, billed_group),
              params: { time_session_group: { billed: '0' } }

        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
        billed_group.reload
        expect(billed_group.billed).to be(true)
        expect(billed_group.invoice_number).to be_present
      end
    end
  end

  # D4 (doc/abrechnung_detail_angleichung_plan.md): the status modal's pair.
  describe 'GET /org/:organisation_id/time_session_groups/:id/billing_status' do
    it 'renders the transition form for admin/finance' do
      get billing_status_organisation_time_session_group_path(organisation, time_session_group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('billing_status_form')
      expect(response.body).to include(I18n.t('views.organisations.time_session_groups.billing_status.invoice_label'))
      expect(response.body).not_to include('translation_missing')
    end

    # Q3 (approved 02.09.): the status is Admin/Finance business. The creator
    # keeps editing name and description but no longer flips the billing
    # state - before the split the combined form walked past the stricter
    # mark_as_billed? through update?.
    context 'as the creator without admin or finance role' do
      let(:creator) { create(:user) }
      let(:creator_role) { create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}") }
      let!(:creator_membership) do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: creator, organisation: organisation, role: creator_role, active: true)
        end
      end
      let(:own_group) do
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session_group, organisation: organisation, creator: creator)
        end
      end

      before do
        sign_out user
        sign_in creator
      end

      it 'denies the form' do
        get billing_status_organisation_time_session_group_path(organisation, own_group)

        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
      end

      it 'denies the transition but still allows renaming' do
        patch billing_status_organisation_time_session_group_path(organisation, own_group),
              params: { time_session_group: { billed: '1', invoice_number: 'INV-X' } }
        expect(own_group.reload.billed).to be(false)

        patch organisation_time_session_group_path(organisation, own_group),
              params: { time_session_group: { name: 'Umbenannt vom Ersteller' } }
        expect(own_group.reload.name).to eq('Umbenannt vom Ersteller')
      end
    end
  end

  describe 'POST /org/:organisation_id/time_session_groups/:id/generate_customer_descriptions' do
    let(:project) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end

    # Since R3 the actor refuses an org that cannot use :customer_description at all,
    # and the factory default (opted in, no credential) is such an org. These examples
    # are about the billed guard and the sync/async threshold, so they need an org
    # that gets PAST the gate. BYOK on the pinned provider is terminal in
    # has_valid_ai_configuration? and therefore independent of any system credential.
    before do
      organisation.update!(ai_enabled: true, ai_provider: ::AiCredential::PROVIDER_OPENAI,
                           ai_access_token: 'sk-org-own-1234567890abcdef')
    end

    describe 'billed-generate guard (R3, plan §9.8-5)' do
      let(:billed_group) do
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session_group, :billed, organisation: organisation, creator: user)
        end
      end
      let!(:billed_session) do
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session,
                 organisation: organisation, project: project, creator: user,
                 time_session_group: billed_group, billed: true,
                 invoice_number: billed_group.invoice_number,
                 customer_description: nil)
        end
      end

      # Regression (plan §9.8-5): before the actor, all LLM calls ran first and
      # every session update then failed at prevent_changes_when_billed — paid
      # calls for guaranteed failures, reported via a success NOTICE.
      it 'refuses a billed group before any LLM call and alerts' do
        allow(CustomerDescriptionGenerator).to receive(:new)
          .and_return(instance_double(CustomerDescriptionGenerator, generate: 'Stub'))

        post generate_customer_descriptions_organisation_time_session_group_path(organisation, billed_group)

        expect(response).to redirect_to(organisation_time_session_group_path(organisation, billed_group))
        expect(flash[:alert]).to eq(I18n.t('services.actors.generate_group_customer_descriptions.group_billed'))
        expect(flash[:notice]).to be_nil
        expect(CustomerDescriptionGenerator).not_to have_received(:new)
        expect(billed_session.reload.customer_description).to be_nil
      end
    end

    # Coverage gaps (plan §6.4): the action had NO request coverage before T2.
    # Job-enqueue assertions deliberately live on the actor-spec level only
    # (plan §9.8-7) — these examples assert response + DB.
    describe 'sync path below the threshold' do
      let!(:open_sessions) do
        ActsAsTenant.with_tenant(organisation) do
          create_list(:time_session, 2,
                      organisation: organisation, project: project, creator: user,
                      time_session_group: time_session_group, customer_description: nil)
        end
      end

      it 'generates synchronously and reports the counters in the notice' do
        allow(CustomerDescriptionGenerator).to receive(:new)
          .and_return(instance_double(CustomerDescriptionGenerator, generate: 'Kundentext'))

        post generate_customer_descriptions_organisation_time_session_group_path(organisation, time_session_group)

        expect(response).to redirect_to(organisation_time_session_group_path(organisation, time_session_group))
        expect(flash[:notice]).to eq(I18n.t('flash.time_session_groups.descriptions_created', count: 2))
        # Single query (per-session #reload would trip Prosopite's N+1 scan).
        descriptions = ActsAsTenant.with_tenant(organisation) do
          TimeSession.where(id: open_sessions.map(&:id)).pluck(:customer_description)
        end
        expect(descriptions).to all(eq('Kundentext'))
      end

      # F1 regression (plan §5-E6, user-approved): a provider outage (generator
      # rescues to nil) used to report "2 Beschreibungen erstellt" — the flash
      # must reflect the failures instead.
      it 'reports failures instead of success when the LLM returns nothing (F1)' do
        allow(CustomerDescriptionGenerator).to receive(:new)
          .and_return(instance_double(CustomerDescriptionGenerator, generate: nil))

        post generate_customer_descriptions_organisation_time_session_group_path(organisation, time_session_group)

        expect(response).to redirect_to(organisation_time_session_group_path(organisation, time_session_group))
        expect(flash[:notice]).to eq(I18n.t('flash.time_session_groups.descriptions_failed', count: 2))
      end
    end

    describe 'async path above the threshold' do
      let!(:open_sessions) do
        ActsAsTenant.with_tenant(organisation) do
          create_list(:time_session, 11,
                      organisation: organisation, project: project, creator: user,
                      time_session_group: time_session_group, customer_description: nil)
        end
      end

      it 'redirects with the background notice and no synchronous LLM call' do
        allow(CustomerDescriptionGenerator).to receive(:new)

        post generate_customer_descriptions_organisation_time_session_group_path(organisation, time_session_group)

        expect(response).to redirect_to(organisation_time_session_group_path(organisation, time_session_group))
        expect(flash[:notice]).to eq(I18n.t('flash.time_session_groups.descriptions_background'))
        expect(CustomerDescriptionGenerator).not_to have_received(:new)
      end
    end

    describe 'authorization' do
      let(:plain_user) { create(:user) }
      let(:plain_role) { create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}") }
      let!(:plain_membership) do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: plain_user, organisation: organisation, role: plain_role, active: true)
        end
      end
      let!(:open_session) do
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session,
                 organisation: organisation, project: project, creator: user,
                 time_session_group: time_session_group, customer_description: nil)
        end
      end

      it 'denies a plain member who is not the creator' do
        sign_out user
        sign_in plain_user
        allow(CustomerDescriptionGenerator).to receive(:new)

        post generate_customer_descriptions_organisation_time_session_group_path(organisation, time_session_group)

        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
        expect(CustomerDescriptionGenerator).not_to have_received(:new)
        expect(open_session.reload.customer_description).to be_nil
      end
    end

    # In dev/test the actor re-raises unexpected errors, so generate_error_message's
    # else-arm only ever runs in production — stub the actor to pin the generic
    # fallback (raw error text must not reach the flash).
    describe 'internal_error fallback (production-only failure branch)' do
      it 'falls back to the generic alert for non-domain failure codes' do
        failure = Actors::BaseActor::Result.new(
          success: false, errors: ['Faraday::ConnectionFailed: connection refused'], code: :internal_error
        )
        actor = instance_double(Actors::GenerateGroupCustomerDescriptions, call: failure)
        allow(Actors::GenerateGroupCustomerDescriptions).to receive(:new).and_return(actor)

        post generate_customer_descriptions_organisation_time_session_group_path(organisation, time_session_group)

        expect(response).to redirect_to(organisation_time_session_group_path(organisation, time_session_group))
        expect(flash[:alert]).to eq(I18n.t('flash.time_session_groups.descriptions_error'))
      end
    end
  end

  describe 'Authorization' do
    let(:other_organisation) { create(:organisation) }
    let(:unauthorized_user) { create(:user) }
    let(:other_role) { create(:role, organisation: other_organisation) }
    let!(:other_membership) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:membership, user: unauthorized_user, organisation: other_organisation, role: other_role, active: true)
      end
    end

    before do
      sign_out user
      sign_in unauthorized_user
      # User is signed in but has no access to the time_session_group's organisation
    end

    it 'denies access to chronological view for unauthorized users' do
      get chronological_organisation_time_session_group_path(organisation, time_session_group)
      expect(response).to have_http_status(:redirect)
      # Redirects to either select_organisation or root_path depending on middleware
    end

    it 'denies access to aggregated view for unauthorized users' do
      get aggregated_organisation_time_session_group_path(organisation, time_session_group)
      expect(response).to have_http_status(:redirect)
    end

    it 'denies access to customer export view for unauthorized users' do
      get customer_export_organisation_time_session_group_path(organisation, time_session_group)
      expect(response).to have_http_status(:redirect)
    end
  end
end
