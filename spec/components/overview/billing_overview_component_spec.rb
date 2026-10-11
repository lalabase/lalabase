# frozen_string_literal: true

require 'rails_helper'

# What: Overview::BillingOverviewComponent — the 3-stage hours billing pipeline.
# Type: Component spec (render_inline; route-free, PortfolioStats stubbed; the org primitive mocked).
# Why:  Pins the gate (time access), the three pipeline stages, and the all-zero empty state.
RSpec.describe Overview::BillingOverviewComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:briefing) { instance_double(Dashboard::DailyBriefing) }

  def component(stage_keys: nil)
    described_class.new(organisation: organisation, user: user, briefing: briefing, stage_keys: stage_keys)
  end

  let(:portfolio) do
    instance_double(Overview::PortfolioStats, without_billing_hours: 5.0, in_billing_hours: 2.0, billed_hours: 8.0)
  end

  describe '#should_render?' do
    it 'renders only with time access in some project' do
      allow(Current).to receive(:area_access_anywhere?).with(user, organisation, :time_sessions, :read).and_return(true)
      expect(component.should_render?).to be true
    end

    it 'is hidden without time access anywhere' do
      allow(Current).to receive(:area_access_anywhere?).with(user, organisation, :time_sessions, :read).and_return(false)
      expect(component.should_render?).to be false
    end
  end

  context 'when rendering (has time access)' do
    before { allow(Current).to receive(:area_access_anywhere?).and_return(true) }

    it 'renders the three pipeline stages with their hours' do
      allow(Overview::PortfolioStats).to receive(:new).and_return(
        instance_double(Overview::PortfolioStats, without_billing_hours: 5.0, in_billing_hours: 2.0, billed_hours: 8.0)
      )
      render_inline(component)
      expect(page).to have_text(I18n.t('views.time_sessions.billing_status.without_billing'))
      expect(page).to have_text(I18n.t('views.time_sessions.billing_status.in_billing'))
      expect(page).to have_text(I18n.t('views.time_sessions.billing_status.billed'))
      expect(page).to have_text('5.0')
      expect(page).to have_text('8.0')
    end

    it 'shows the empty state when every stage is zero' do
      allow(Overview::PortfolioStats).to receive(:new).and_return(
        instance_double(Overview::PortfolioStats, without_billing_hours: 0.0, in_billing_hours: 0.0, billed_hours: 0.0)
      )
      render_inline(component)
      expect(page).to have_text(I18n.t('overview.billing.empty'))
    end

    describe 'drill-down links' do
      before { allow(Overview::PortfolioStats).to receive(:new).and_return(portfolio) }

      # Per-box correctness: each box must link to ITS OWN billing status only (not a swap, not the
      # bundled default) and be pinned all-time, so the opened list reproduces exactly that box's
      # figure. Iterating STAGE_KEYS doubles as whitelist positive-iteration: a dropped stage fails.
      described_class::STAGE_KEYS.each do |key|
        it "links the #{key} box to the all-time list filtered to #{key} only" do
          render_inline(component)
          link = page.find(:link, text: I18n.t("views.time_sessions.billing_status.#{key}"))
          expect(link[:href]).to include("status_filters%5B%5D=#{key}")
          expect(link[:href]).to include('date_range=all')
          # exactly one status -> kills a swap that bundles the others, and the all-3 default
          expect(link[:href].scan('status_filters%5B%5D=').size).to eq(1)
        end
      end

      it 'renders exactly one drill-down link per visible stage (no extra/missing links)' do
        render_inline(component)
        time_links = page.all(:link).map { |a| a[:href] }.compact.select { |h| h.include?('time-tracking') }
        expect(time_links.size).to eq(3)
      end
    end

    describe 'stage picker' do
      before { allow(Overview::PortfolioStats).to receive(:new).and_return(portfolio) }

      it 'renders only the selected stages' do
        render_inline(component(stage_keys: %w[without_billing billed]))
        expect(page).to have_text(I18n.t('views.time_sessions.billing_status.without_billing'))
        expect(page).to have_text(I18n.t('views.time_sessions.billing_status.billed'))
        expect(page).not_to have_text(I18n.t('views.time_sessions.billing_status.in_billing'))
      end

      # Defense in depth: the registry parse whitelists on SAVE, but the component must ALSO drop a
      # forged key on render (a config persisted before the whitelist, or a hand-edited payload).
      it 'drops a forged/bogus stage_key (component-level whitelist)' do
        render_inline(component(stage_keys: %w[bogus without_billing]))
        expect(page).to have_text(I18n.t('views.time_sessions.billing_status.without_billing'))
        time_links = page.all(:link).map { |a| a[:href] }.compact.select { |h| h.include?('time-tracking') }
        expect(time_links.size).to eq(1) # only the valid stage survives; bogus produced no box/link
      end

      it 'renders the selected stages in canonical order, not the stored order' do
        render_inline(component(stage_keys: %w[billed without_billing]))
        body = page.text
        expect(body.index(I18n.t('views.time_sessions.billing_status.without_billing')))
          .to be < body.index(I18n.t('views.time_sessions.billing_status.billed'))
      end

      it 'adapts the grid column count to the number of visible stages' do
        render_inline(component(stage_keys: %w[without_billing billed]))
        expect(page).to have_css('div.grid.grid-cols-2')
      end
    end

    # any_hours? must look only at the SELECTED stages: an all-zero selection shows the empty state
    # even when an UNSELECTED stage has hours (kills "any_hours? checks all three figures").
    it 'shows the empty state when the selected stages are zero, ignoring unselected non-zero stages' do
      allow(Overview::PortfolioStats).to receive(:new).and_return(
        instance_double(Overview::PortfolioStats, without_billing_hours: 0.0, in_billing_hours: 2.0, billed_hours: 8.0)
      )
      render_inline(component(stage_keys: %w[without_billing]))
      expect(page).to have_text(I18n.t('overview.billing.empty'))
    end

    it 'does not render at all when the stage selection is empty' do
      expect(component(stage_keys: []).should_render?).to be false
    end

    # All-bogus selection must HIDE the widget, not show an empty-state box. This pins the STAGE_KEYS
    # whitelist in #visible_stage_keys via the should_render? path (the render path alone tolerates a
    # bogus key, since #stages selects from the canonical list — so this is the load-bearing guard).
    it 'is hidden when every selected stage is forged/bogus (whitelist empties the selection)' do
      expect(component(stage_keys: %w[bogus]).should_render?).to be false
    end
  end
end
