# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'UserPreferences', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  # The section name picks the template to render. Before 26.09.2026 any value was
  # passed to `render`, so ?section= could render any other view of the app.
  describe 'GET /user_preferences/edit with a section parameter' do
    it 'renders a known section' do
      get edit_user_preferences_path(section: 'datetime')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="preferences_date_display_global_format"')
    end

    ['edit', '../layouts/application', 'shared/flash'].each do |section|
      it "falls back to the general section for #{section.inspect}" do
        get edit_user_preferences_path(section: section)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('id="preferences_items_per_page"')
      end
    end
  end

  describe 'PATCH /user_preferences' do
    context 'when updating general preferences' do
      it 'redirects to general edit view after successful update' do
        patch user_preferences_path, params: {
          current_section: 'general',
          preferences: {
            items_per_page: '20',
            post_direction: 'reverse'
          }
        }

        expect(response).to redirect_to(general_user_preferences_path)
        follow_redirect!

        expect(request.path).to eq(general_user_preferences_path)
        expect(response).to have_http_status(:ok)
        expect(flash[:notice]).to eq(I18n.t('user_preferences.settings_updated'))
      end

      it 'updates the items_per_page preference' do
        patch user_preferences_path, params: {
          current_section: 'general',
          preferences: {
            items_per_page: '100'
          }
        }

        user.reload
        expect(user.preferences['items_per_page']).to eq('100')
      end

      it 'updates the post_direction preference' do
        patch user_preferences_path, params: {
          current_section: 'general',
          preferences: {
            post_direction: 'reverse'
          }
        }

        user.reload
        expect(user.preferences['post_direction']).to eq('reverse')
      end
    end

    context 'when updating description_collapse' do
      it 'persists a valid value' do
        patch user_preferences_path, params: {
          current_section: 'tickets',
          preferences: { description_collapse: 'always_full' }
        }

        expect(user.reload.preferences['description_collapse']).to eq('always_full')
      end

      it 'persists the auto value' do
        patch user_preferences_path, params: {
          current_section: 'tickets',
          preferences: { description_collapse: 'auto' }
        }

        expect(user.reload.preferences['description_collapse']).to eq('auto')
      end

      it 'discards an invalid value (whitelist hardening)' do
        # The JSONB column has no model-level validation, so the controller is
        # the only gate against a crafted value poisoning the preference.
        patch user_preferences_path, params: {
          current_section: 'tickets',
          preferences: { description_collapse: 'evil' }
        }

        expect(user.reload.preferences).not_to have_key('description_collapse')
      end
    end

    context 'when updating meeting_detection_mode (Gespräche Slice 5)' do
      it 'persists a valid value and redirects back to the meetings section' do
        patch user_preferences_path, params: {
          current_section: 'meetings',
          preferences: { meeting_detection_mode: 'ai' }
        }

        expect(response).to redirect_to(meetings_user_preferences_path)
        expect(user.reload.preferences['meeting_detection_mode']).to eq('ai')
      end

      it 'discards an unknown value (whitelist hardening — same gate as description_collapse)' do
        patch user_preferences_path, params: {
          current_section: 'meetings',
          preferences: { meeting_detection_mode: 'llm_always' }
        }

        expect(user.reload.preferences).not_to have_key('meeting_detection_mode')
      end

      it 'derives the meetings section from the param alone (no current_section)' do
        # Covers the determine_current_section_from_params fallback branch: the
        # meeting_detection_mode param routes back to the meetings section even
        # without an explicit current_section field.
        patch user_preferences_path, params: {
          preferences: { meeting_detection_mode: 'ai' }
        }

        expect(response).to redirect_to(meetings_user_preferences_path)
        expect(user.reload.preferences['meeting_detection_mode']).to eq('ai')
      end
    end

    context 'when updating name_display (name display S1)' do
      it 'persists a valid value and redirects back to the display section' do
        patch user_preferences_path, params: {
          current_section: 'display',
          preferences: { name_display: 'first_last_initial' }
        }

        expect(response).to redirect_to(display_user_preferences_path)
        expect(user.reload.preferences['name_display']).to eq('first_last_initial')
      end

      it "drops the legacy 'circle' value (the picture stopped being a mode on 05.09.2026)" do
        patch user_preferences_path, params: {
          current_section: 'display',
          preferences: { name_display: 'circle' }
        }

        expect(user.reload.preferences).not_to have_key('name_display')
        expect(user.preference_store.name_display_mode).to eq('full')
      end

      it 'discards an unknown value (whitelist hardening — same gate as the other enum prefs)' do
        patch user_preferences_path, params: {
          current_section: 'display',
          preferences: { name_display: 'gravatar' }
        }

        expect(user.reload.preferences).not_to have_key('name_display')
      end

      it 'derives the display section from the param alone (no current_section)' do
        patch user_preferences_path, params: {
          preferences: { name_display: 'initial_last' }
        }

        expect(response).to redirect_to(display_user_preferences_path)
        expect(user.reload.preferences['name_display']).to eq('initial_last')
      end
    end

    context 'when updating datetime preferences' do
      it 'redirects to datetime edit view after successful update' do
        patch user_preferences_path, params: {
          current_section: 'datetime',
          preferences: {
            date_display: {
              global_format: 'german',
              custom_format: '%d.%m.%Y %H:%M'
            }
          }
        }

        expect(response).to redirect_to(datetime_user_preferences_path)
        follow_redirect!

        expect(request.path).to eq(datetime_user_preferences_path)
        expect(response).to have_http_status(:ok)
        expect(flash[:notice]).to eq(I18n.t('user_preferences.settings_updated'))
      end

      it 'updates the global_format preference' do
        patch user_preferences_path, params: {
          current_section: 'datetime',
          preferences: {
            date_display: {
              global_format: 'international'
            }
          }
        }

        user.reload
        expect(user.preferences.dig('date_display', 'global_format')).to eq('international')
      end

      it 'updates custom format for specific areas' do
        patch user_preferences_path, params: {
          current_section: 'datetime',
          preferences: {
            date_display: {
              areas: {
                posts: 'custom',
                ticket_header: 'inherit'
              },
              areas_custom: {
                posts: '%Y-%m-%d'
              }
            }
          }
        }

        user.reload
        expect(user.preferences.dig('date_display', 'areas', 'posts')).to eq('custom')
        expect(user.preferences.dig('date_display', 'areas_custom', 'posts')).to eq('%Y-%m-%d')
      end
    end

    context 'when updating language preferences' do
      it 'redirects to language edit view after successful update' do
        patch user_preferences_path, params: {
          user: {
            language_preference: 'en'
          }
        }

        expect(response).to redirect_to(language_user_preferences_path)
        follow_redirect!

        expect(request.path).to eq(language_user_preferences_path)
        expect(response).to have_http_status(:ok)
        # The notice answers in the language just chosen. Read in :en explicitly: since
        # 10.09.2026 the request hands the thread back, so the test's own locale stays German.
        expect(flash[:notice]).to eq(I18n.t('user_preferences.language_updated', locale: :en))
      end

      it 'updates the language preference' do
        patch user_preferences_path, params: {
          user: {
            language_preference: 'en'
          }
        }

        user.reload
        expect(user.language_preference).to eq('en')
      end

      it 'changes the I18n locale' do
        I18n.locale = :de

        patch user_preferences_path, params: {
          user: {
            language_preference: 'en'
          }
        }

        user.reload
        expect(user.language_preference).to eq('en')
      end

      it 'redirects to language edit view even on failure' do
        allow_any_instance_of(User).to receive(:update).and_return(false)

        patch user_preferences_path, params: {
          user: {
            language_preference: 'invalid'
          }
        }

        expect(response).to redirect_to(language_user_preferences_path)
        follow_redirect!
        expect(flash[:alert]).to eq(I18n.t('user_preferences.language_update_failed'))
      end
    end

    context 'when current_section is not provided' do
      it 'determines section from general parameters' do
        patch user_preferences_path, params: {
          preferences: {
            items_per_page: '50'
          }
        }

        expect(response).to redirect_to(general_user_preferences_path)
      end

      it 'determines section from ticket parameters' do
        patch user_preferences_path, params: {
          preferences: {
            description_collapse: 'auto'
          }
        }

        expect(response).to redirect_to(tickets_user_preferences_path)
      end

      it 'determines section from datetime parameters' do
        patch user_preferences_path, params: {
          preferences: {
            date_display: {
              global_format: 'relative'
            }
          }
        }

        expect(response).to redirect_to(datetime_user_preferences_path)
      end

      it 'determines section from language parameters' do
        patch user_preferences_path, params: {
          user: {
            language_preference: 'de'
          }
        }

        expect(response).to redirect_to(language_user_preferences_path)
      end

      it 'defaults to general section when no specific parameters' do
        patch user_preferences_path, params: {
          preferences: {}
        }

        expect(response).to redirect_to(general_user_preferences_path)
      end
    end

    context 'when update fails' do
      before do
        allow_any_instance_of(User::PreferencesForm).to receive(:update).and_return(false)
      end

      it 'renders edit template with error message' do
        patch user_preferences_path, params: {
          current_section: 'general',
          preferences: {
            items_per_page: '20'
          }
        }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('user_preferences.settings_update_failed'))
      end
    end

    context 'with JSON format' do
      it 'returns success response with items_per_page' do
        patch user_preferences_path, params: {
          current_section: 'general',
          preferences: {
            items_per_page: '50'
          }
        }, headers: { 'Accept' => 'application/json' }

        expect(response).to have_http_status(:ok)
        json_response = JSON.parse(response.body)
        expect(json_response['success']).to be true
        expect(json_response['items_per_page']).to eq(50)
      end

      it 'returns error response on failure' do
        allow_any_instance_of(User::PreferencesForm).to receive(:update).and_return(false)
        allow_any_instance_of(User).to receive_message_chain(:errors, :full_messages).and_return(['Error message'])

        patch user_preferences_path, params: {
          current_section: 'general',
          preferences: {
            items_per_page: '50'
          }
        }, headers: { 'Accept' => 'application/json' }

        expect(response).to have_http_status(:unprocessable_content)
        json_response = JSON.parse(response.body)
        expect(json_response['success']).to be false
        expect(json_response['errors']).to include('Error message')
      end
    end
  end

  describe 'GET /user_preferences/general' do
    it 'shows the general edit form' do
      get general_user_preferences_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.general.items_per_page.label'))
    end

    it 'handles empty preferences gracefully' do
      user.update(preferences: {})

      get general_user_preferences_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.general.items_per_page.label'))

      # Preferences are not automatically saved to DB (only in memory)
      user.reload
      expect(user.preferences).to eq({})
    end
  end

  describe 'GET /user_preferences/display (name display S1)' do
    it 'shows the four mode options with the viewer name previewed' do
      user.update!(first_name: 'Guido', last_name: 'Boyke')

      get display_user_preferences_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.display.name_display.label'))
      User::PreferenceStore::NAME_DISPLAY_MODES.each do |mode|
        expect(response.body).to include(I18n.t("user_preferences.edit.display.name_display.#{mode}"))
      end
      # The previews render through the SAME component the app uses.
      expect(response.body).to include('Guido B.')
      expect(response.body).to include('G. Boyke')
      expect(response.body).to include('GB')
    end
  end

  describe 'GET /user_preferences/tickets' do
    it 'shows the ticket settings form with the moved ticket preferences' do
      get tickets_user_preferences_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.tickets.timeline_order.label'))
      expect(response.body).to include(I18n.t('user_preferences.edit.tickets.description_collapse.label'))
      expect(response.body).to include(I18n.t('user_preferences.edit.tickets.intro'))
    end

    it 'no longer shows ticket preferences on the general page' do
      get general_user_preferences_path

      expect(response.body).not_to include(I18n.t('user_preferences.edit.tickets.timeline_order.label'))
    end
  end

  describe 'GET /user_preferences/meetings (Gespräche Slice 5)' do
    it 'shows the detection mode setting with the offline default selected' do
      get meetings_user_preferences_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.meetings.detection_mode.label'))
      expect(response.body).to include(I18n.t('user_preferences.edit.meetings.intro'))
    end

    context 'when no organisation of the user has AI available' do
      it 'renders the AI option disabled with an explanatory hint' do
        get meetings_user_preferences_path

        expect(response.body).to include('option disabled="disabled" value="ai"')
        expect(response.body).to include(I18n.t('user_preferences.edit.meetings.detection_mode.ai_unavailable_hint'))
      end
    end

    context 'when at least one organisation has AI available' do
      before do
        organisation.update!(ai_enabled: true)
        allow_any_instance_of(Organisation).to receive(:has_valid_ai_configuration?).and_return(true)
      end

      it 'renders the AI option selectable' do
        get meetings_user_preferences_path

        expect(response.body).not_to include('option disabled="disabled" value="ai"')
        expect(response.body).not_to include(I18n.t('user_preferences.edit.meetings.detection_mode.ai_unavailable_hint'))
      end

      # R2 (doc/ai_feature_registry_plan.md §6): this setting drives exactly ONE path
      # — the LLM leg of the participant detection — so it must ask the SAME row as
      # the detect button it enables (meetings/_form_fields, pinned in
      # meeting_detect_participants_spec 'feature key (R2)'). Any other key would
      # reproduce "the same gate, two answers", the defect S1c removed here, in
      # feature form. Measured: retyping the view's key to :chat left 123 examples
      # green before this pair existed.
      it 'disables the AI option when :meeting_participant_detection says no' do
        allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
        allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve)
          .with(:meeting_participant_detection, anything)
          .and_return(Lalabase::Llm::FeatureRegistry::Availability.new(available: false, reason: :no_credential))

        get meetings_user_preferences_path

        expect(response.body).to include('option disabled="disabled" value="ai"')
      end

      # The other direction — without it, a view that answered no for every key would
      # satisfy the example above and pin nothing.
      it 'keeps the AI option selectable when a foreign row says no' do
        allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
        allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve)
          .with(:meeting_summary, anything)
          .and_return(Lalabase::Llm::FeatureRegistry::Availability.new(available: false, reason: :no_credential))

        get meetings_user_preferences_path

        expect(response.body).not_to include('option disabled="disabled" value="ai"')
      end
    end
  end

  describe 'GET /user_preferences/datetime' do
    it 'shows the datetime edit form' do
      get datetime_user_preferences_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.datetime.global_format.label'))
    end
  end

  describe 'GET /user_preferences/language' do
    it 'shows the language edit form' do
      get language_user_preferences_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.language.interface_language'))
    end
  end

  describe 'GET /user_preferences/edit' do
    it 'renders the general section by default' do
      get edit_user_preferences_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.general.items_per_page.label'))
    end
  end

  describe 'backward-compatibility redirects' do
    it 'redirects general_show to general' do
      get general_show_user_preferences_path
      expect(response).to redirect_to('/user_preferences/general')
    end

    it 'redirects datetime_show to datetime' do
      get datetime_show_user_preferences_path
      expect(response).to redirect_to('/user_preferences/datetime')
    end

    it 'redirects language_show to language' do
      get language_show_user_preferences_path
      expect(response).to redirect_to('/user_preferences/language')
    end
  end
end
