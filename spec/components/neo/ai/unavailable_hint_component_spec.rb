# frozen_string_literal: true

require 'rails_helper'

# What: Contract of the shared "this AI feature is withheld" box (R4).
# Type: Component spec — rendering + the render?/silence rules.
# Why (philosophy): R4 moves thirteen surfaces onto the feature gate, and each of them
#   needs the same box AND the same rule about WHEN it may speak. Written per call site
#   that rule is eight copies of `reason != :ai_disabled` — the duplicated-enforcement
#   smell CLAUDE.md names, and the kind of line that is quietly wrong at the ninth site.
#   These examples are what makes the one predicate safe to rely on.
# Contract: never speaks for a working feature; silent about the opt-in unless the caller
#   asks; the sentence always comes from the registry, never from a local translation.
RSpec.describe Neo::Ai::UnavailableHintComponent, type: :component do
  let(:organisation) { create(:organisation) }

  def availability(reason, provider: 'openai')
    Lalabase::Llm::FeatureRegistry::Availability.new(
      available: reason.nil?, reason: reason, required_provider: provider
    )
  end

  def render_hint(**overrides)
    render_inline(described_class.new(
                    **{ availability: availability(:no_credential), organisation: organisation }.merge(overrides)
                  ))
  end

  def provider_label
    AiCredential.provider_display_names.fetch('openai', 'openai')
  end

  describe 'when it must stay quiet' do
    it 'renders nothing for a feature that works' do
      render_hint(availability: availability(nil))

      expect(rendered_content.strip).to be_empty
    end

    it 'renders nothing about a missing opt-in by default' do
      # The R4 rule: a surface that showed nothing to an org without the opt-in keeps
      # showing nothing. Only the reasons R4 actually introduces get a voice.
      render_hint(availability: availability(:ai_disabled))

      expect(rendered_content.strip).to be_empty
    end

    it 'renders nothing without an organisation, because that IS the opt-in case' do
      # resolve(key, nil) answers :ai_disabled, so a nil availability must land in the
      # same branch. Treating it as its own case would silently drop the notice the chat
      # composer shows when it is built without an org.
      render_hint(availability: nil, organisation: nil)

      expect(rendered_content.strip).to be_empty
    end
  end

  describe 'when the caller asks it to explain the opt-in' do
    it 'uses the canonical opt-in copy rather than a forked one' do
      render_hint(availability: availability(:ai_disabled), explain_opt_in: true)

      expect(rendered_content).to include(I18n.t('shared.ai.disabled_member_hint'))
    end

    it 'still says the opt-in sentence when there is no organisation at all' do
      render_hint(availability: nil, organisation: nil, explain_opt_in: true)

      expect(rendered_content).to include(I18n.t('shared.ai.disabled_member_hint'))
    end
  end

  describe 'the sentence' do
    # The R3 rule: ONE text source. A caller writing t('shared.ai.unavailable.…') by hand
    # is what this component exists to prevent, so the reason set and its copy stay a
    # single contract owned by the registry.
    it 'comes from the registry, interpolating the display name and not the routing key' do
      render_hint(availability: availability(:no_credential))

      expect(rendered_content).to include(
        I18n.t('shared.ai.unavailable.no_credential', provider: provider_label, current: provider_label)
      )
      expect(rendered_content).not_to include('openai')
    end

    it 'follows the reason instead of always saying the same thing' do
      render_hint(availability: availability(:provider_incapable))

      expect(rendered_content).to include(
        I18n.t('shared.ai.unavailable.provider_incapable', provider: provider_label, current: provider_label)
      )
    end
  end

  describe 'the feature label' do
    # Needed where two lanes live in ONE form (the document forms): a bare reason cannot
    # say WHICH of the two checkboxes went away.
    it 'names the feature when the caller passes a key' do
      render_hint(feature: :content_indexing)

      expect(rendered_content).to include(I18n.t('shared.ai.features.content_indexing'))
    end

    it 'is left out when the caller passes none' do
      render_hint

      expect(rendered_content).not_to include(I18n.t('shared.ai.features.content_indexing'))
    end
  end

  describe 'variants' do
    it 'draws a box by default' do
      render_hint

      expect(page).to have_css('div.border-2.bg-cobalt-50')
      expect(page).to have_css('i.bi-info-circle')
    end

    it 'draws the amber warning box on request' do
      render_hint(variant: :warning)

      expect(page).to have_css('div.border-2.bg-amber-50')
      expect(page).to have_css('i.bi-shield-exclamation')
    end

    it 'draws no box and no icon for :plain' do
      # Two surfaces showed this sentence as a quiet paragraph before R4; turning their
      # notice into a bordered panel would be a visual change R4 did not set out to make.
      render_hint(variant: :plain)

      expect(page).not_to have_css('div.border-2')
      expect(page).not_to have_css('i')
      expect(rendered_content).to include(
        I18n.t('shared.ai.unavailable.no_credential', provider: provider_label, current: provider_label)
      )
    end

    it 'keeps :plain a plain block — no flex row where there is no icon to seat' do
      # The absence assertions above are blind to the layout: container_classes used to
      # append `flex items-start gap-2` for EVERY variant, which turns the one :plain
      # call site (the chats#index empty state, inside `text-center`) into a flex
      # container whose single shrink-to-fit child sits at flex-start — left-aligned
      # where the pre-R4 <p> was centred. That is exactly the visual change :plain
      # exists to prevent, so the class list is pinned in both directions.
      render_hint(variant: :plain)

      expect(page).to have_css('div.text-sm.text-cream-900.opacity-70')
      expect(page).not_to have_css('div.flex')
      expect(page).not_to have_css('div.gap-2')
    end

    it 'seats the icon in a flex row for the boxed variants' do
      # The other half: the flex row must survive wherever there IS an icon, otherwise
      # "make :plain plain" would silently flatten the info/warning boxes too.
      render_hint(variant: :warning)

      expect(page).to have_css('div.flex.items-start.gap-2 i.bi-shield-exclamation')
    end

    it 'falls back to the boxed default for an unknown variant instead of raising' do
      render_hint(variant: :nonsense)

      expect(page).to have_css('div.border-2.bg-cobalt-50')
    end
  end

  it 'passes the caller spacing through so the box sits where the control sat' do
    render_hint(classes: 'mb-6')

    expect(page).to have_css('div.mb-6')
  end
end
