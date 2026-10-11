# frozen_string_literal: true

require 'rails_helper'

# What: Request spec for R4 (doc/ai_feature_registry_plan.md §6) — the surfaces that
#   used to offer AI switches on the GDPR opt-in ALONE now ask their feature row.
# Type: Request spec — rendered-body gating of the notes, documents and chat surfaces.
# Why (philosophy): the opt-in says an org MAY use AI, never that it CAN. Every surface
#   here offered a switch to an opted-in org with no usable credential — the user ticked
#   it, saved, and nothing ever happened ("offer, then refuse", the exact UX
#   organisation.rb warns about). Each switch now asks the row that routes the job behind
#   it, so the two cannot disagree, and where the answer is no the user reads why.
# Contract, three states per surface:
#   configured        → the switch, as before
#   opted in, no config → the reason, no switch  (the state R4 introduces)
#   not opted in      → unchanged; surfaces silent before R4 stay silent
# Plus a mutation guard per surface: today every unpinned row answers the same, so a
# mistyped key is invisible in production. Refusing exactly ONE row and leaving a second
# untouched is what makes the key visible. Never a blanket stub on resolve — that answers
# for every key and makes the file blind to the very defect it guards (#402 review).
RSpec.describe 'AI opt-in-only surfaces ask their feature row (R4)', type: :request do
  # Two credentials, not one: the surfaces below span BOTH lanes (create_embeddings is an
  # embedding-lane switch, create_summary and the chat a chat-lane one), and they route
  # independently. code_indexing_enabled is the separate per-org chat beta the chat pages
  # sit behind — unrelated to the AI gate, but without it chats#index never renders.
  let(:organisation) do
    create(:organisation, code_indexing_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-test-1234567890abcdef',
                          embedding_access_token: 'sk-test-1234567890abcdef')
  end
  let(:user) { create(:user) }
  let(:role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Current.user = user
  end

  after { Current.reset }

  def refuse_only(feature_key, reason: :no_credential)
    allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
    allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve)
      .with(feature_key, anything)
      .and_return(Lalabase::Llm::FeatureRegistry::Availability.new(
                    available: false, reason: reason, required_provider: 'openai'
                  ))
  end

  def unavailable_sentence(reason = :no_credential)
    label = AiCredential.provider_display_names.fetch('openai', 'openai')
    I18n.t("shared.ai.unavailable.#{reason}", provider: label, current: label)
  end

  def indexing_label = I18n.t('shared.ai.features.content_indexing')
  def summary_label  = I18n.t('shared.ai.features.document_summary')

  # Every <input> carrying the note's embedding key, as raw tags. Deliberately NOT
  # Capybara.string: one of the note surfaces answers as a turbo_stream, and
  # Nokogiri does not expose <template> children to CSS — a have_css expectation there
  # is vacuously true and the surface silently stops being tested. Anchoring on the
  # name attribute keeps the match independent of Rails' attribute order.
  def embedding_inputs(body)
    body.scan(/<input[^>]*name="note\[create_embeddings\]"[^>]*>/)
  end

  # ---------------------------------------------------------------- notes (2 surfaces)
  #
  # Since doc/notizen_immer_indexiert_plan.md (10.09.2026) a note carries NO indexing
  # switch: it is indexed like a ticket, whenever the org's embedding lane is usable,
  # and EmbeddingProcessingService decides at the seam. So R4's three states collapse
  # into one for these surfaces: no switch, no reason, no forced-off field, whatever
  # the registry answers. Pinned in every state, or a switch could creep back into
  # one of them unseen.
  describe 'the note forms carry no indexing switch' do
    let(:note) do
      ActsAsTenant.with_tenant(organisation) { create(:note, project: project, organisation: organisation) }
    end

    # Two, not three: the full-page form left on 2026-09-30, notes/new without a frame
    # redirects to the knowledge page (knowledge_lane_spec).
    def get_new_frame
      get new_organisation_project_note_path(organisation, project, frame: 'content'),
          headers: { 'Turbo-Frame' => 'knowledge_display_frame' }
    end

    def get_edit_frame
      get edit_organisation_project_note_path(organisation, project, note, format: :turbo_stream)
    end

    { '_note_new_for_frame' => :get_new_frame,
      '_note_edit' => :get_edit_frame }.each do |surface, request_method|
      context "in #{surface}" do
        it 'offers no switch while the embedding lane is configured' do
          send(request_method)

          expect(response).to have_http_status(:ok)
          expect(embedding_inputs(response.body)).to be_empty
          expect(response.body).not_to include('create_embeddings')
        end

        it 'shows neither a reason nor a forced-off field when the embedding lane is refused' do
          refuse_only(:content_indexing)
          send(request_method)

          expect(response.body).not_to include(unavailable_sentence)
          expect(response.body).not_to include(indexing_label)
          expect(embedding_inputs(response.body)).to be_empty
        end

        context 'when the org never opted in' do
          let(:organisation) { create(:organisation, :ai_disabled, code_indexing_enabled: true) }

          it 'stays silent, exactly as before' do
            send(request_method)

            expect(response.body).not_to include('create_embeddings')
            expect(response.body).not_to include(I18n.t('shared.ai.disabled_member_hint'))
          end
        end
      end
    end
  end

  # ------------------------------------------------------- documents (one switch left)
  #
  # Plan §7.1 split the two switches by lane; doc/notizen_immer_indexiert_plan.md
  # removed the indexing one. What is left is the summary switch (chat lane,
  # :document_summary), which still asks its own row, and NOTHING about indexing in
  # any state: no switch, no reason, no field.
  describe 'the document forms ask :document_summary for the one switch they keep' do
    let(:document) do
      ActsAsTenant.with_tenant(organisation) do
        doc = create(:document, project: project, organisation: organisation)
        version = create(:document_version, document: doc, organisation: organisation)
        doc.update!(current_version: version)
        doc
      end
    end

    def get_new_page = get new_organisation_project_document_path(organisation, project)

    def get_new_frame
      get new_organisation_project_document_path(organisation, project, frame: 'content'),
          headers: { 'Turbo-Frame' => 'knowledge_display_frame' }
    end

    # The version form's summary checkbox binds create_summary since S4 of
    # doc/dokumentansicht_plan.md (D2); it used to post :process_with_ai, a name
    # nothing read, which R4 had gated but deliberately not repaired.
    def get_version_form = get organisation_project_document_path(organisation, project, document, frame: 'content')

    # D3 (S4 of doc/dokumentansicht_plan.md): the ONE sentence the document forms say
    # about indexing, and only while the org has AI on and the embedding lane refuses.
    def locked_sentence = I18n.t('views.organisations.documents.ai_locked_state.sentence')

    { 'documents/_document_form' => [:get_new_page, 'create_summary'],
      '_document_new_for_frame' => [:get_new_frame, 'create_summary'],
      '_version_form' => [:get_version_form, 'create_summary'] }.each do |surface, (request_method, summary_field)|
      context "in #{surface}" do
        it 'offers the summary switch and no indexing switch while both lanes are configured' do
          send(request_method)

          expect(response.body).to include(summary_field)
          expect(response.body).not_to include('create_embeddings')
          expect(response.body).not_to include(unavailable_sentence)
          expect(response.body).not_to include(locked_sentence)
        end

        it 'withdraws the summary switch with its name when the chat lane is refused' do
          refuse_only(:document_summary)
          send(request_method)

          expect(response.body).not_to include(summary_field)
          expect(response.body).to include(summary_label)
          expect(response.body).not_to include(indexing_label)
        end

        it 'says the locked sentence and nothing else about indexing when the embedding lane is refused' do
          refuse_only(:content_indexing)
          send(request_method)

          expect(response.body).to include(summary_field)
          expect(response.body).not_to include('create_embeddings')
          expect(response.body).not_to include(indexing_label)
          expect(response.body).not_to include(unavailable_sentence)
          expect(response.body).to include(locked_sentence)
        end

        context 'when the org never opted in' do
          let(:organisation) { create(:organisation, :ai_disabled, code_indexing_enabled: true) }

          it 'stays silent about the summary, exactly as before R4' do
            send(request_method)

            expect(response.body).not_to include(summary_field)
            expect(response.body).not_to include(I18n.t('shared.ai.disabled_member_hint'))
            expect(response.body).not_to include(locked_sentence)
          end

          # Verify finding 1, only reachable on this surface: the switch sits in a
          # wrapper div under the opt-in, and R4 initially left that wrapper outside
          # it: an opted-out org got an empty flex box with mb-4 where it used to get
          # nothing. Text assertions alone are blind to that.
          if surface == '_document_new_for_frame'
            it 'renders no empty options wrapper either' do
              send(request_method)

              expect(response.body).not_to include('flex flex-wrap gap-4 mb-4')
            end
          end

          if surface == 'documents/_document_form'
            it 'leaks no option markers either' do
              send(request_method)

              expect(response.body).not_to include('<!-- Embeddings option -->')
              expect(response.body).not_to include('<!-- Summary option -->')
            end
          end
        end
      end
    end
  end

  # ------------------------------------------------------------------ chats (:chat row)
  #
  # projekt_chat_abbau replaced this whole block. It used to drive the per-project chat
  # index, its title-box action and its chat page -- three request surfaces that no
  # longer exist. The RULE did not change and is worth as much as before, so it is
  # asked of the surface that survived: the assistant panel, which renders the same
  # ChatContainerComponent and the same transparency notice.
  #
  # Kept at REQUEST level deliberately, even though chat_container_component_spec pins
  # R4 on the component: the component spec cannot see whether the panel's controller
  # reaches the component at all.
  describe 'the assistant panel asks :chat' do
    let!(:chat) do
      ActsAsTenant.with_tenant(organisation) do
        create(:chat, organisation: organisation, user: user)
      end
    end

    let!(:assistant_permission) do
      role = user.role_in_organisation(organisation)
      create(:permission, role: role, category: 'assistant', action: 'use_assistant', allowed: true)
    end

    before { organisation.update!(assistant_enabled: true) }

    def panel = get(organisation_assistant_panel_path(organisation_id: organisation.id))

    def transparency_snippet
      I18n.t('views.organisations.chats.chat_show.ai_transparency',
             provider: AiCredential.provider_display_names.fetch('openai', 'openai'))
    end

    it 'offers the composer while the chat lane is configured' do
      panel

      expect(response.body).to include(transparency_snippet)
      expect(response.body).not_to include(unavailable_sentence)
    end

    it 'explains the reason instead of the composer when the chat lane is refused' do
      refuse_only(:chat)
      panel

      expect(response.body).to include(unavailable_sentence)
      expect(response.body).not_to include(transparency_snippet)
    end

    # The half that makes the example above mean something: the surface asks the :chat
    # ROW, not "is any AI refused". A refusal aimed elsewhere must not touch it.
    it 'ignores a refusal aimed at a different registry row' do
      refuse_only(:content_indexing)
      panel

      expect(response.body).to include(transparency_snippet)
      expect(response.body).not_to include(unavailable_sentence)
    end
  end
end
