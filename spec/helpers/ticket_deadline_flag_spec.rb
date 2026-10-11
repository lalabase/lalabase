# frozen_string_literal: true

require 'rails_helper'

# What: the sign in front of a title in the list - red for a deadline that has
#   passed, amber for one that is today, nothing otherwise (designer,
#   07.09.2026, "Überfällig-Markierung: roter Balken durch Zeichen ersetzen").
# Type: helper spec.
# Why: it replaced a red bar at the row's left edge, and that bar meant
#   something else entirely - HIGH PRIORITY, not a deadline. Two states must not
#   share one colour ("heute fällig" is an announcement, "überfällig" a
#   failure), and a done ticket must never nag.
RSpec.describe TicketsHelper, type: :helper do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user) } }

  before do
    ActsAsTenant.current_tenant = organisation
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                                             { 'value' => 'closed', 'labels' => { 'de' => 'Zu', 'en' => 'Closed' },
                                               'system_functions' => [SystemFunctions::Registry::IS_CLOSED] }
                                           ] })
    end
  end

  def with_due(date, status: 'open')
    ticket.update!(custom_attributes: { Ticket::DUE_DATE_KEY => date&.iso8601, 'status' => status }.compact)
    ticket
  end

  describe '#ticket_deadline_flag' do
    it 'is nothing without a deadline: no sign and no placeholder' do
      expect(helper.ticket_deadline_flag(ticket)).to be_nil
    end

    it 'is nothing for a deadline still ahead' do
      expect(helper.ticket_deadline_flag(with_due(Date.current + 3))).to be_nil
    end

    it 'names the day in the caption when the deadline has passed' do
      html = helper.ticket_deadline_flag(with_due(Date.current - 2))

      expect(html).to include(TicketsHelper::DEADLINE_FLAG_COLORS[:overdue])
      # The caption carries the DATE, not just the state: "overdue" alone leaves
      # the reader to open the ticket to find out since when.
      expect(html).to include(I18n.l(Date.current - 2, format: :default))
      # A sign without a word needs both: a title for the pointer and a name for
      # the keyboard, which never sees a tooltip.
      expect(html).to match(/aria-label="[^"]+"/)
      expect(html).to match(/title="[^"]+"/)
    end

    it 'wears the other colour for a deadline that is today' do
      html = helper.ticket_deadline_flag(with_due(Date.current))

      expect(html).to include(TicketsHelper::DEADLINE_FLAG_COLORS[:due_today])
      expect(html).not_to include(TicketsHelper::DEADLINE_FLAG_COLORS[:overdue])
    end

    it 'keeps the two states apart, or the sign would say nothing' do
      expect(TicketsHelper::DEADLINE_FLAG_COLORS[:overdue])
        .not_to eq(TicketsHelper::DEADLINE_FLAG_COLORS[:due_today])
    end

    # ⚠️ Done work does not nag. A deadline that has passed on a ticket nobody
    # has to do any more is not a failure, it is history - and a list full of
    # red signs on closed tickets teaches the reader to stop seeing the colour.
    it 'is silent on a ticket that is done, however long the deadline has passed' do
      expect(helper.ticket_deadline_flag(with_due(Date.current - 30, status: 'closed'))).to be_nil
    end

    it 'is silent while the caller says the row already says it' do
      expect(helper.ticket_deadline_flag(with_due(Date.current - 2), suppressed: true)).to be_nil
    end
  end

  describe '#ticket_deadline_flag_suppressed?' do
    let(:due_column) { { key: "custom_#{Ticket::DUE_DATE_KEY}" } }

    it 'is silent while the due column is on screen: the date there carries the state' do
      expect(helper.ticket_deadline_flag_suppressed?([{ key: 'assignees' }, due_column])).to be(true)
    end

    it 'is silent in a view whose own question is the deadline' do
      expect(helper.ticket_deadline_flag_suppressed?([{ key: 'assignees' }], ['custom_due_date'])).to be(true)
    end

    # Deliberately a substring match: the condition arrives spelled as the
    # column key from the bar and as the bare attribute name from a folder rule,
    # and an exact list would be a third place to keep in step. A preset like
    # "overdue" is an OPERATOR on this same field, so it comes in under one of
    # these two names too.
    it 'recognises the condition under either of its spellings' do
      expect(helper.ticket_deadline_flag_suppressed?([], [Ticket::DUE_DATE_KEY])).to be(true)
      expect(helper.ticket_deadline_flag_suppressed?([], ["custom_#{Ticket::DUE_DATE_KEY}"])).to be(true)
    end

    it 'stays out of the way otherwise' do
      expect(helper.ticket_deadline_flag_suppressed?([{ key: 'assignees' }], %w[status])).to be(false)
    end
  end
end
