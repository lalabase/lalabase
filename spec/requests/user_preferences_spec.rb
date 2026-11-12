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

  # A section's anchor on the one preferences page (UserPreferencesHelper).
  def section_path(key)
    edit_user_preferences_path(anchor: "section-#{key}")
  end

  def page
    Nokogiri::HTML(response.body)
  end

  # Until 26.09.2026 the section name picked the template, and any value was passed to
  # `render`, so ?section= could render any other view of the app. Since 2026-11-12
  # there is one page and no template to pick.
  describe 'GET /user_preferences/edit with a section parameter' do
    ['datetime', 'edit', '../layouts/application', 'shared/flash'].each do |section|
      it "renders the one page for #{section.inspect}" do
        get edit_user_preferences_path(section: section)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('id="preferences_items_per_page"')
        expect(response.body).to include('id="preferences_date_display_global_format"')
      end
    end
  end

  # One page of sections (user, 2026-11-12): the head of the application, every
  # section a form of its own, a change saved at once.
  describe 'GET /user_preferences/edit: the page' do
    let(:sections) { UserPreferencesController::SECTIONS }

    before do
      user.update!(first_name: 'Lena', last_name: 'Beispiel')
      get edit_user_preferences_path
    end

    it 'is titled by its area, with the person below, once' do
      expect(page.css('main h1').map { |h1| h1.text.squish }).to eq([I18n.t('navigation.preferences')])
      expect(page.at_css('main').text).to include('Lena Beispiel')
    end

    it 'lists its sections in one order, each under the anchor other pages link to' do
      expect(page.css('main section[id]').map { |section| section['id'] })
        .to eq(sections.map { |key| "section-#{key}" })
      expect(page.css('main section h2').map { |h2| h2.text.squish })
        .to eq(sections.map { |key| I18n.t("user_preferences.edit.sections.#{key}") })
    end

    it 'gives every section a form of its own that names the section' do
      sections.each do |key|
        forms = page.css("#section-#{key} form")
        expect(forms.size).to eq(1), key
        expect(forms.first.at_css('input[name="current_section"]')['value']).to eq(key)
      end
    end

    it 'saves a change at once in every section, and keeps a button for a browser without scripts' do
      sections.each do |key|
        section = page.at_css("#section-#{key}")
        expect(section['data-controller']).to eq('preferences-autosave'), key
        expect(section.at_css('form')['data-action']).to eq('change->preferences-autosave#save'), key
        expect(section.at_css('[role="status"][data-preferences-autosave-target="status"]')).to be_present, key
        expect(section.at_css('noscript button[type="submit"]')).to be_present, key
        expect(section.css('form > button, form > div > button[type="submit"]')).to be_empty, key
      end
    end

    # The outline of the page (shared/_page_outline, F46): one link per section, in the
    # page's order, each to an anchor the page has. Plain #anchors, so the jump works
    # without a script; the script only marks the current one.
    it 'lists its sections in an outline that leads to each of them' do
      outline = page.at_css("main nav.page-outline[aria-label='#{I18n.t('navigation.on_this_page')}']")
      links = outline.css('a')

      expect(links.map { |link| link.text.squish })
        .to eq(sections.map { |key| I18n.t("user_preferences.edit.sections.#{key}") })
      expect(links.map { |link| link['href'] }).to eq(sections.map { |key| "#section-#{key}" })
      links.each { |link| expect(page.at_css("main section#{link['href']}")).to be_present, link['href'] }
      expect(outline['data-controller']).to eq('page-outline')
      # No link is marked by the server: which section is current is known in the browser only.
      expect(outline.css('[aria-current]')).to be_empty
    end

    it 'puts the outline before the sections, so the keyboard reaches it first' do
      order = page.css('main nav.page-outline, main section[id]').map(&:name)

      expect(order.first).to eq('nav')
      expect(order.count('nav')).to eq(1)
    end

    # A preference says how the application behaves for the person. What the others
    # see of them (picture, shown email) stands on the account's profile tab since
    # 2026-11-12, and the API tokens are a function with an entry of their own.
    it 'holds neither the picture nor the email for the others' do
      expect(response.body).not_to include('user[avatar]')
      expect(response.body).not_to include('user[email_visibility]')
      expect(response.body).not_to include('user[contact_email]')
    end

    it 'holds no API tokens: they are a function with an entry of their own' do
      expect(page.css('main a').map { |link| link['href'] }).not_to include(users_personal_access_tokens_path)
      expect(page.css('#sidebar a').map { |link| link['href'] })
        .to include(users_personal_access_tokens_path, edit_user_preferences_path)
    end
  end

  describe 'the former section pages' do
    UserPreferencesController::SECTIONS.each do |key|
      it "redirects /user_preferences/#{key} to its section of the one page" do
        get "/user_preferences/#{key}"

        expect(response).to redirect_to(section_path(key))
      end
    end

    it 'sends the former profile page on to the account, where picture and shown email are' do
      get '/user_preferences/display'

      expect(response).to redirect_to(edit_user_registration_path(anchor: 'section-display'))
    end

    it 'leads every anchor to a section the page has' do
      get edit_user_preferences_path

      UserPreferencesController::SECTIONS.each do |key|
        expect(page.at_css("section#section-#{key}")).to be_present, key
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

        expect(response).to redirect_to(section_path('general'))
        follow_redirect!

        expect(request.path).to eq(edit_user_preferences_path)
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

        expect(response).to redirect_to(section_path('meetings'))
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

        expect(response).to redirect_to(section_path('meetings'))
        expect(user.reload.preferences['meeting_detection_mode']).to eq('ai')
      end
    end

    context 'when updating name_display (name display S1)' do
      it 'persists a valid value and redirects back to its section' do
        patch user_preferences_path, params: {
          current_section: 'general',
          preferences: { name_display: 'first_last_initial' }
        }

        expect(response).to redirect_to(section_path('general'))
        expect(user.reload.preferences['name_display']).to eq('first_last_initial')
      end

      it "drops the legacy 'circle' value (the picture stopped being a mode on 05.09.2026)" do
        patch user_preferences_path, params: {
          current_section: 'general',
          preferences: { name_display: 'circle' }
        }

        expect(user.reload.preferences).not_to have_key('name_display')
        expect(user.preference_store.name_display_mode).to eq('full')
      end

      it 'discards an unknown value (whitelist hardening — same gate as the other enum prefs)' do
        patch user_preferences_path, params: {
          current_section: 'general',
          preferences: { name_display: 'gravatar' }
        }

        expect(user.reload.preferences).not_to have_key('name_display')
      end

      it 'derives its section from the param alone (no current_section)' do
        patch user_preferences_path, params: {
          preferences: { name_display: 'initial_last' }
        }

        expect(response).to redirect_to(section_path('general'))
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

        expect(response).to redirect_to(section_path('datetime'))
        follow_redirect!

        expect(request.path).to eq(edit_user_preferences_path)
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

        expect(response).to redirect_to(section_path('language'))
        follow_redirect!

        expect(request.path).to eq(edit_user_preferences_path)
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

        expect(response).to redirect_to(section_path('language'))
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

        expect(response).to redirect_to(section_path('general'))
      end

      it 'determines section from ticket parameters' do
        patch user_preferences_path, params: {
          preferences: {
            description_collapse: 'auto'
          }
        }

        expect(response).to redirect_to(section_path('tickets'))
      end

      it 'determines section from datetime parameters' do
        patch user_preferences_path, params: {
          preferences: {
            date_display: {
              global_format: 'relative'
            }
          }
        }

        expect(response).to redirect_to(section_path('datetime'))
      end

      it 'determines section from language parameters' do
        patch user_preferences_path, params: {
          user: {
            language_preference: 'de'
          }
        }

        expect(response).to redirect_to(section_path('language'))
      end

      it 'defaults to general section when no specific parameters' do
        patch user_preferences_path, params: {
          preferences: {}
        }

        expect(response).to redirect_to(section_path('general'))
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
        expect(json_response['reload']).to be false
      end

      # What the page's autosave gets (preferences_autosave_controller). `reload` says the
      # page the reader looks at is stale now; the notice then waits for the page it
      # loads next, because the line beside the heading does not survive the reload.
      def save_as_script(params)
        patch user_preferences_path, params: params, headers: { 'Accept' => 'application/json' }
        JSON.parse(response.body)
      end

      it 'tells the page to reload after another language, with the notice in that language' do
        user.update!(language_preference: 'de')

        answer = save_as_script(current_section: 'language', user: { language_preference: 'en' })

        expect(response).to have_http_status(:ok)
        expect(answer).to include('success' => true, 'reload' => true)
        expect(user.reload.language_preference).to eq('en')
        expect(flash[:notice]).to eq(I18n.t('user_preferences.language_updated', locale: :en))
      end

      it 'does not reload for the language the person already has' do
        user.update!(language_preference: 'de')

        answer = save_as_script(current_section: 'language', user: { language_preference: 'de' })

        expect(answer).to include('success' => true, 'reload' => false)
        expect(flash[:notice]).to be_nil
      end

      it 'tells the page to reload after another session length: the layout counts down to the old one' do
        answer = save_as_script(current_section: 'session', user: { session_timeout_minutes: '120' })

        expect(response).to have_http_status(:ok)
        expect(answer).to include('success' => true, 'reload' => true)
        expect(user.reload.session_timeout_minutes).to eq(120)
      end

      it 'does not reload for the session length the person already has' do
        answer = save_as_script(current_section: 'session',
                                user: { session_timeout_minutes: user.session_timeout_minutes.to_s })

        expect(answer).to include('success' => true, 'reload' => false)
      end

      it 'refuses a session length outside the list with the reason, and keeps the old one' do
        before = user.session_timeout_minutes

        answer = save_as_script(current_section: 'session', user: { session_timeout_minutes: '7' })

        expect(response).to have_http_status(:unprocessable_content)
        expect(answer['success']).to be false
        expect(answer['errors']).to be_present
        expect(user.reload.session_timeout_minutes).to eq(before)
      end

      it 'saves one section and leaves the others alone' do
        user.update!(preferences: user.preferences.merge('post_direction' => 'reverse', 'name_display' => 'initial_last'))

        save_as_script(current_section: 'general', preferences: { items_per_page: '100' })

        user.reload
        expect(user.items_per_page_preference).to eq(100)
        expect(user.preferences).to include('post_direction' => 'reverse', 'name_display' => 'initial_last')
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

  describe 'the general section' do
    it 'shows the general edit form' do
      get edit_user_preferences_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.general.items_per_page.label'))
    end

    it 'handles empty preferences gracefully' do
      user.update(preferences: {})

      get edit_user_preferences_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.general.items_per_page.label'))

      # Preferences are not automatically saved to DB (only in memory)
      user.reload
      expect(user.preferences).to eq({})
    end
  end

  describe 'the name display (S1), in the general section' do
    it 'shows the four mode options with the viewer name previewed' do
      user.update!(first_name: 'Guido', last_name: 'Boyke')

      get edit_user_preferences_path

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

  describe 'the tickets section' do
    it 'shows the ticket settings form with the moved ticket preferences' do
      get edit_user_preferences_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.tickets.timeline_order.label'))
      expect(response.body).to include(I18n.t('user_preferences.edit.tickets.description_collapse.label'))
      expect(response.body).to include(I18n.t('user_preferences.edit.tickets.intro'))
    end
  end

  describe 'the meetings section (Gespräche Slice 5)' do
    it 'shows the detection mode setting with the offline default selected' do
      get edit_user_preferences_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.meetings.detection_mode.label'))
      expect(response.body).to include(I18n.t('user_preferences.edit.meetings.intro'))
    end

    context 'when no organisation of the user has AI available' do
      it 'renders the AI option disabled with an explanatory hint' do
        get edit_user_preferences_path

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
        get edit_user_preferences_path

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

        get edit_user_preferences_path

        expect(response.body).to include('option disabled="disabled" value="ai"')
      end

      # The other direction — without it, a view that answered no for every key would
      # satisfy the example above and pin nothing.
      it 'keeps the AI option selectable when a foreign row says no' do
        allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
        allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve)
          .with(:meeting_summary, anything)
          .and_return(Lalabase::Llm::FeatureRegistry::Availability.new(available: false, reason: :no_credential))

        get edit_user_preferences_path

        expect(response.body).not_to include('option disabled="disabled" value="ai"')
      end
    end
  end

  describe 'the datetime section' do
    it 'shows the datetime edit form' do
      get edit_user_preferences_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.edit.datetime.global_format.label'))
    end
  end

  describe 'the language section' do
    it 'shows the language edit form' do
      get edit_user_preferences_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('user_preferences.language.interface_language'))
    end
  end

  describe 'backward-compatibility redirects' do
    %w[general datetime language].each do |key|
      it "redirects #{key}_show to the #{key} section" do
        get "/user_preferences/#{key}_show"

        expect(response).to redirect_to(section_path(key))
      end
    end
  end
end
