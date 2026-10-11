# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SubjectTimeSummaryComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project) }
  let(:user) { create(:user) }
  let(:component) { described_class.new(subject: ticket, user: user) }

  before do
    ActsAsTenant.current_tenant = organisation
    # Create membership for user
    create(:membership, user: user, organisation: organisation)
  end

  def allow_time_write(allowed)
    allow_any_instance_of(ProjectPolicy)
      .to receive(:area_access?).with(:time_sessions, :write).and_return(allowed)
  end

  describe '#render?' do
    context 'when summary is nil and the user may not write time' do
      before do
        allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(nil)
        allow_time_write(false)
      end

      it 'returns false' do
        expect(component.render?).to be false
      end
    end

    context 'when summary has 0 hours and the user may not write time' do
      before do
        allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(
          { hours: 0.0, scope: :all, can_view: true }
        )
        allow_time_write(false)
      end

      it 'returns false' do
        expect(component.render?).to be false
      end
    end

    # D1 of doc/zeit_erfassen_an_der_summe_plan.md: with the area clock gone, a
    # ticket without booked time still needs an entry point for writers.
    context 'when summary is nil but the user may write time' do
      before do
        allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(nil)
        allow_time_write(true)
      end

      it 'renders the quiet capture entry instead of a sum' do
        render_inline(component)

        expect(page).to have_text(I18n.t('components.subject_time_summary.capture_time'))
        expect(page).to have_no_css('.bi-chevron-down')
        expect(page).to have_css("turbo-frame[loading='lazy'][src*='subject_popover']")
      end
    end

    context 'when summary has hours' do
      before do
        allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(
          { hours: 2.5, scope: :all, can_view: true }
        )
      end

      it 'returns true' do
        expect(component.render?).to be true
      end
    end
  end

  describe 'rendering' do
    context 'with all scope' do
      before do
        allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(
          { hours: 2.5, scope: :all, can_view: true }
        )
      end

      it 'renders clock-format hours with scope label (user mockup 05.09.2026)' do
        render_inline(component)

        expect(page).to have_text('2:30 h')
        expect(page).to have_text(I18n.t('components.subject_time_summary.scope.all'))
        expect(page).to have_css('i.bi-clock')
      end
    end

    context 'with own scope' do
      before do
        allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(
          { hours: 1.25, scope: :own, can_view: true }
        )
      end

      it 'renders hours with own scope label' do
        render_inline(component)

        expect(page).to have_text('1:15 h')
        expect(page).to have_text(I18n.t('components.subject_time_summary.scope.own'))
        expect(page).to have_css('i.bi-clock')
      end
    end

    context 'with exactly 1 hour' do
      before do
        allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(
          { hours: 1.0, scope: :all, can_view: true }
        )
      end

      it 'renders a full hour as 1:00 h' do
        render_inline(component)

        expect(page).to have_text('1:00 h')
      end
    end

    context 'with multiple hours' do
      before do
        allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(
          { hours: 3.75, scope: :all, can_view: true }
        )
      end

      it 'renders three quarters as :45' do
        render_inline(component)

        expect(page).to have_text('3:45 h')
      end
    end

    context 'with very small hours' do
      before do
        allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(
          { hours: 0.17, scope: :own, can_view: true }
        )
      end

      it 'rounds sub-hour values to whole minutes (0.17 h -> 0:10 h)' do
        render_inline(component)

        expect(page).to have_text('0:10 h')
        expect(page).to have_text(I18n.t('components.subject_time_summary.scope.own'))
      end
    end

    context 'in compact mode' do
      let(:component) { described_class.new(subject: ticket, user: user, mode: 'compact') }

      before do
        allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(
          { hours: 2.5, scope: :all, can_view: true }
        )
      end

      it 'renders the same clock format without the scope label' do
        render_inline(component)

        expect(page).to have_text('2:30 h')
        expect(page).to have_no_text(I18n.t('components.subject_time_summary.scope.all'))
        expect(page).to have_css('i.bi-clock')
      end
    end
  end

  # The chip no longer links out: it is a button, and behind it sits the
  # two-column capture popover as a lazy turbo-frame (the header render never
  # pays for the booking list). The drill-down address moved into the popover
  # footer — pinned end to end in time_sessions_ticket_drilldown_spec.
  describe 'the capture popover frame' do
    before do
      allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(
        { hours: 2.5, scope: :all, can_view: true }
      )
    end

    it 'renders a button with a lazy frame pointing at the popover endpoint, ticket preselected' do
      render_inline(component)

      expect(page).to have_css("span[class*='js-time-chip-#{ticket.id}'] button[data-action*='neo-inline-popover#toggle']")
      expect(page).to have_css('.bi-chevron-down')
      frame = page.find("turbo-frame#subject_time_popover_#{ticket.id}")
      expect(frame[:loading]).to eq('lazy')
      expect(frame[:src]).to include('/time-tracking/subject_popover')
      expect(frame[:src]).to include("ticket_id=#{ticket.id}")
      expect(frame[:src]).to include("project_id=#{project.id}")
      expect(frame[:target]).to eq('_top')
    end

    context 'with a meeting subject' do
      let(:meeting) { create(:meeting, project: project, organisation: organisation, creator: user) }
      let(:component) { described_class.new(subject: meeting, user: user) }

      it 'points the frame at the popover endpoint by meeting id' do
        render_inline(component)

        frame = page.find("turbo-frame#subject_time_popover_#{meeting.id}")
        expect(frame[:src]).to include("meeting_id=#{meeting.id}")
        expect(frame[:src]).not_to include('ticket_id=')
      end
    end
  end

  # A meeting is a time subject like a ticket — same chip, meeting-nested billing
  # routes. Locks the subject generalisation (URL switch + per-subject chip class).
  describe 'with a meeting subject' do
    let(:meeting) { create(:meeting, project: project, organisation: organisation, creator: user) }
    let(:component) { described_class.new(subject: meeting, user: user) }

    before do
      allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(
        { hours: 0.75, scope: :all, can_view: true }
      )
    end

    it 'renders the hours chip for the meeting' do
      render_inline(component)

      expect(page).to have_text('0:45 h')
      expect(page).to have_css("[class*='js-time-chip-#{meeting.id}']")
      expect(page).to have_css('i.bi-clock')
    end

    # "Zeit eintragen" next to a meeting is ambiguous — the meeting header
    # already shows a time, its duration — so the meeting zero state says
    # "Aufwand buchen" (user, 05.09.2026).
    context 'without booked time, for a writer' do
      before do
        allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(nil)
        allow_time_write(true)
      end

      it 'says the effort wording, not the time wording' do
        render_inline(component)

        expect(page).to have_text(I18n.t('components.subject_time_summary.capture_effort'))
        expect(page).to have_no_text(I18n.t('components.subject_time_summary.capture_time'))
      end
    end

    # The billing-assignment popover is gone (designer handoff §9): assigning is
    # a monthly task and lives in the times list. The chip renders NO assignment
    # form for anybody, admin included.
    context 'for an account admin' do
      before do
        admin_role = create(:role, organisation: organisation, title: 'account_admin')
        user.memberships.find_by(organisation: organisation).update!(role: admin_role)
        create(:time_session, meeting: meeting, creator: user, duration: 45,
                              organisation: organisation, project: project)
      end

      it 'renders no assignment form, only the capture popover frame' do
        render_inline(component)

        expect(page).to have_no_css('form')
        expect(page).to have_css("turbo-frame#subject_time_popover_#{meeting.id}")
      end
    end
  end

  # T20: the chip is the third surface that shows a billing state, and since
  # 30.08.2026 all three carry ONE picture and ONE word. It used to draw four
  # circle glyphs of its own and read its own locale keys.
  describe 'the billing state' do
    def summarise(shares:, status:, percent: nil)
      allow_any_instance_of(SubjectTimeSummaryService).to receive(:call).and_return(
        total_minutes: shares.values.sum, hours: 1.0, scope: :all,
        billing_status: status, shares: shares, percent: percent, can_view: true
      )
    end

    it 'draws the share bar of the time list, with the minutes in its label' do
      summarise(shares: { 'billed' => 60, 'in_billing' => 0, 'without_billing' => 30 },
                status: :mixed, percent: 67)

      rendered = render_inline(component)

      expect(rendered.css('[role="img"]').map { |n| n['aria-label'] })
        .to include("#{I18n.t('views.time_sessions.billing_status.billed')}: 01:00 · #{I18n.t('views.time_sessions.billing_status.without_billing')}: 00:30")
      expect(rendered.css('[class*="bg-time-"]')).not_to be_empty
    end

    it 'says the word the list and the column say, with the share' do
      summarise(shares: { 'billed' => 60, 'without_billing' => 30 }, status: :mixed, percent: 67)

      rendered = render_inline(component)

      expect(rendered.css('[title]').map { |n| n['title'] }.join(' ')).to include('teilweise 67 %')
    end

    it 'says the plain word when only one bucket is filled' do
      summarise(shares: { 'in_billing' => 60 }, status: :in_billing)

      rendered = render_inline(component)

      expect(rendered.css('[title]').map { |n| n['title'] }.join(' '))
        .to include(I18n.t('views.time_sessions.billing_status.in_billing'))
    end

    # The compact form has no room for a bar and never had a glyph either.
    it 'stays a bare duration in the compact form' do
      summarise(shares: { 'without_billing' => 60 }, status: :without_billing)
      compact = described_class.new(subject: ticket, user: user, mode: 'compact')

      rendered = render_inline(compact)

      expect(rendered.css('[role="img"]')).to be_empty
    end
  end
end
