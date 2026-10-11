# frozen_string_literal: true

require 'rails_helper'

# Neo::Chat::StyleControlComponent — the answer-style selects under the composer.
#
# Intent per test: the selected option IS the stored state (display and control
# are the same element), every step of both dimensions stays reachable, the
# control is only EMPHASISED where the stored level differs from the neutral
# middle step, the write target carries the dimension, and the component degrades
# silently in the viewer-agnostic broadcast context where there is no
# current_user.
#
# It was six pills until 27.08.2026, which is why several examples read as
# "still true after the shape changed": what a step means, and which one is
# stored, did not change with it.
RSpec.describe Neo::Chat::StyleControlComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }

  def render_control
    fake = double('helpers').as_null_object
    allow(fake).to receive(:organisation_chat_style_preference_path) do |_org, dimension:|
      "/style-path/#{dimension}"
    end
    allow(fake).to receive(:protect_against_forgery?).and_return(false)
    allow_any_instance_of(described_class).to receive(:helpers).and_return(fake)
    render_inline(described_class.new(current_user: user, current_organisation: organisation))
  end

  def label(dimension, level)
    I18n.t("views.organisations.chats.style_level.#{dimension}.#{level}")
  end

  describe 'rendering' do
    it 'offers every step of both dimensions' do
      render_control

      # In the options, not on the surface: the control shows one step and offers
      # three. Every one of them stays reachable without a second request, which
      # is the reason the stored level is absolute and not a ±1 nudge.
      %w[technicality length].each do |dimension|
        (1..3).each do |level|
          expect(page).to have_css('option', text: label(dimension, level), visible: :all)
        end
      end
    end

    it 'shows ONE value per dimension, not all six steps at once' do
      render_control

      # The point of the shape: two selects, each with a single selected option.
      # A regression to the pill row would put six visible controls back on a
      # panel that is 380px wide.
      expect(page).to have_css('select', count: 2, visible: :all)
      expect(page).to have_css('option[selected]', count: 2, visible: :all)
    end

    it 'sends the dimension in the URL and the level in the field' do
      render_control

      # The update action reads params[:dimension] and params[:level]; this
      # control's shape must not change what it is handed.
      forms = page.all('form', visible: :all)
      expect(forms.map { |form| form['action'] })
        .to contain_exactly('/style-path/technicality', '/style-path/length')
      expect(page).to have_css('select[name="level"]', count: 2, visible: :all)
      expect(page).to have_css('form input[name="_method"][value="patch"]', count: 2, visible: :all)
    end

    it 'auto-submits on change instead of asking for a second click' do
      render_control

      expect(page).to have_css('form[data-controller="auto-submit"]', count: 2, visible: :all)
    end

    it 'renders both dimension labels' do
      render_control

      expect(page).to have_text(I18n.t('views.organisations.chats.style_level.dimensions.technicality'))
      expect(page).to have_text(I18n.t('views.organisations.chats.style_level.dimensions.length'))
    end

    it 'carries the stable turbo-stream target id' do
      render_control
      expect(page).to have_css(".#{described_class::DOM_CLASS}")
    end
  end

  describe 'the selected option IS the stored state' do
    it 'selects the neutral middle step when nothing is stored' do
      render_control

      # 2/2 default → "mittel"/"medium" selected in both dimensions. This is also
      # why no reset link exists: resetting = picking the middle step.
      expect(page).to have_css('option[selected]', count: 2, visible: :all)
      expect(page).to have_css('option[selected]', text: label('technicality', 2), visible: :all)
      expect(page).to have_css('option[selected]', text: label('length', 2), visible: :all)
    end

    it 'selects the stored steps when a row exists' do
      create(:chat_style_preference, organisation: organisation, user: user, technicality: 3, length: 1)
      render_control

      expect(page).to have_css('option[selected]', text: label('technicality', 3), visible: :all)
      expect(page).to have_css('option[selected]', text: label('length', 1), visible: :all)
      # And the previously-default steps are NOT marked any more.
      expect(page).to have_no_css('option[selected]', text: label('technicality', 2), visible: :all)
    end

    it 'emphasises only the dimension that differs from the neutral step' do
      create(:chat_style_preference, organisation: organisation, user: user, technicality: 3, length: 2)
      render_control

      # A control sitting on its default has nothing to announce, so it wears the
      # quiet outline; a deliberately chosen level wears the filled one. Without
      # this the row is emphasised everywhere, which emphasises nothing.
      chosen = page.all('select', visible: :all).select { |s| s['class'].include?(described_class::SELECT_CHOSEN.split.first) }
      expect(chosen.map { |s| s['aria-label'] })
        .to eq([I18n.t('views.organisations.chats.style_level.dimensions.technicality')])
    end

    it 'reads the level of the passed organisation, not another org’s row' do
      other_organisation = create(:organisation)
      ActsAsTenant.with_tenant(other_organisation) do
        create(:chat_style_preference, organisation: other_organisation, user: user, technicality: 1)
      end
      create(:chat_style_preference, organisation: organisation, user: user, technicality: 3)

      render_control

      expect(page).to have_css('option[selected]', text: label('technicality', 3), visible: :all)
    end

    it 'never creates a row just by rendering' do
      # resolve_for is read-only — a mutation switching it to a find_or_create
      # would silently write a row for every chat page view.
      expect { render_control }.not_to change(ChatStylePreference, :count)
    end
  end

  describe 'render? gate' do
    it 'renders nothing without a current_user (viewer-agnostic broadcast)' do
      render_inline(described_class.new(current_user: nil, current_organisation: organisation))
      expect(page.native.text).to be_blank
    end

    it 'renders nothing without a current_organisation' do
      render_inline(described_class.new(current_user: user, current_organisation: nil))
      expect(page.native.text).to be_blank
    end
  end
end
