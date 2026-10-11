# frozen_string_literal: true

require 'rails_helper'

# What: the P4c progress notice partial, rendered once per state.
# Type: View spec (unit render).
# Why (philosophy): the partial picks its colours from a literal Hash with `.fetch`,
#   and NOTHING binds that Hash's keys to Embeddings::SwitchProgress::STATES. A state
#   added with locale texts but without a tone entry raises KeyError — a 500 on the
#   customer's settings page — while every other guard stays green: the service spec
#   only reads the locale file, and the request spec only drives the states that exist
#   today (P4c review, I3). Rendering EVERY state is the only check that fails at the
#   moment the two lists drift apart.
# Contract: every state in STATES except :none renders without raising and prints its
#   own title; :none renders nothing at all.
RSpec.describe 'organisations/ai_settings/_switch_progress', type: :view do
  def render_state(state, remaining: 3, total: 10)
    assign(:switch_progress,
           Embeddings::SwitchProgress::Result.new(state: state, remaining: remaining, total: total))
    render partial: 'organisations/ai_settings/switch_progress'
    rendered
  end

  # The loop IS the guard — a hand-written example per state would have to be
  # remembered alongside the tone entry, which is exactly the coupling that fails.
  (Embeddings::SwitchProgress::STATES - [:none]).each do |state|
    it "renders the #{state} state with its own title" do
      html = render_state(state)

      expect(html).to include("data-switch-progress=\"#{state}\"")
      expect(html).to include(
        I18n.t("views.organisations.ai_settings.packages.progress.#{state}_title")
      )
      # No missing-translation markup anywhere in the block — catches a state whose
      # body key was forgotten, which would otherwise render as visible debug text on
      # a customer page.
      expect(html).not_to include('translation missing')
    end
  end

  it 'renders nothing for :none' do
    expect(render_state(:none, remaining: nil, total: nil)).to be_blank
  end

  # The bar is the one place a number reaches the markup as a style, so a percent that
  # disagreed with the sentence would be invisible to a text assertion.
  it 'sizes the progress bar from the same percentage it prints' do
    html = render_state(:building, remaining: 3, total: 10)

    expect(html).to include('width: 70%')
    expect(html).to include(
      I18n.t('views.organisations.ai_settings.packages.progress.building_body',
             remaining: 3, total: 10, percent: 70)
    )
  end
end
