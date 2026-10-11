# frozen_string_literal: true

require 'rails_helper'

# Neo::Chat::PersonaControlComponent — the standing persona choice in the
# assistant's settings (gear in the panel header).
#
# Intent per test: the offered pool is the pickable one (org row wins over a
# global row under the same key), the blank option is a real state and not
# padding, the SELECTED option is what is actually in effect rather than what the
# column stores, and a pool with nothing in it renders nothing at all.
#
# The three "in effect" examples are the point of the file. The control and
# ChatResponseJob read the same resolver, so an example that pins what the select
# shows also pins what the system prompt gets. Where they were allowed to drift,
# the surface named one persona and the answer used another, with nothing saying
# so.
RSpec.describe Neo::Chat::PersonaControlComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }

  def render_control
    fake = double('helpers').as_null_object
    allow(fake).to receive(:organisation_assistant_preference_path) { |_args| '/assistant-preference' }
    allow(fake).to receive(:protect_against_forgery?).and_return(false)
    allow_any_instance_of(described_class).to receive(:helpers).and_return(fake)
    render_inline(described_class.new(current_user: user, current_organisation: organisation))
  end

  def choose!(persona)
    ChatStylePreference.set_persona!(user: user, organisation: organisation, prompt_persona_id: persona.id)
  end

  # What the browser will submit: the option carrying the `selected` attribute,
  # or "" when only the blank option is there to be picked.
  def selected_value
    node = page.find('select#assistant_persona_select')
    node.all('option[selected]').first&.[]('value') || ''
  end

  describe 'the offered pool' do
    it 'offers the organisation-wide default as a blank option plus every pickable persona' do
      global = create(:prompt_persona, key: 'deep_dive')
      render_control

      expect(page).to have_css("select#assistant_persona_select option[value='']",
                               text: I18n.t('views.organisations.assistant_panels.settings.persona_default'))
      expect(page).to have_css("select#assistant_persona_select option[value='#{global.id}']")
    end

    # An org publishing its own row under a global key SUPERSEDES it (the
    # ?from=<key> flow in Organisations::PromptPersonasController exists to do
    # exactly that). Only one of the two may be offered, or picking either would
    # be picking the same thing twice.
    it 'offers the organisation override instead of the global row it supersedes' do
      global = create(:prompt_persona, key: 'deep_dive')
      override = create(:prompt_persona, organisation: organisation, key: 'deep_dive')

      render_control

      expect(page).to have_css("select#assistant_persona_select option[value='#{override.id}']")
      expect(page).to have_no_css("select#assistant_persona_select option[value='#{global.id}']")
    end

    it 'renders nothing at all when the pool is empty' do
      expect(render_control.to_html).to be_blank
    end
  end

  describe 'what the control shows' do
    it 'preselects nothing when there is no standing choice' do
      create(:prompt_persona, key: 'deep_dive')
      render_control

      expect(selected_value).to eq('')
    end

    it 'preselects the stored persona' do
      persona = create(:prompt_persona, key: 'deep_dive')
      choose!(persona)

      render_control

      expect(selected_value).to eq(persona.id)
    end

    # Retired org-wide after it was picked. The select has to fall back to the
    # blank option in the same moment the job falls back to the org default,
    # otherwise it names a persona that is no longer being used.
    # A second, still-active persona keeps the pool non-empty on purpose: with the
    # retired one alone there is nothing to choose, the component declines to
    # render, and the example would pass without ever reaching the select.
    it 'falls back to the blank option once the stored persona is deactivated' do
      persona = create(:prompt_persona, key: 'deep_dive')
      create(:prompt_persona, key: 'still_here')
      choose!(persona)
      persona.update!(active: false)

      render_control

      expect(page).to have_css('select#assistant_persona_select')
      expect(selected_value).to eq('')
    end

    # The same fall-back for the other way a choice stops being in effect: the
    # org publishes its own row under that key, so the global one somebody picked
    # is superseded rather than deactivated. The select must not keep pointing at
    # a row it no longer even offers.
    #
    # ⚠️ Measured: this example does NOT break when #resolved_persona is put back
    # on the wider `available_for` pool, and that is not a weak assertion, it is
    # the shape of the bug. The superseded row is not among the options either
    # way, so the SELECT looks identical while the system prompt silently keeps
    # the old fragment. The mutation is caught where the two can be told apart:
    # chat_style_preference_spec's "returns nil once an organisation override
    # supersedes" and chat_spec's pin twin. This one pins the visible contract.
    it 'falls back to the blank option once an organisation override supersedes the stored persona' do
      global = create(:prompt_persona, key: 'deep_dive')
      choose!(global)
      create(:prompt_persona, organisation: organisation, key: 'deep_dive')

      render_control

      expect(selected_value).to eq('')
    end
  end
end
