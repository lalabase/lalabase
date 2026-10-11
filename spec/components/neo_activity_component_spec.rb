# frozen_string_literal: true

require 'rails_helper'

# Guard: the ticket timeline follows the same shortening rule as the project
# feed (Aktivitätenfeed, 10.09.2026).
#
# The rule lives in TimelineHelper, and both surfaces render this component -
# the ticket timeline through its second branch (no project). These examples
# are the proof that this branch asks the helper as well instead of printing
# the pair itself; the project branch is covered in
# neo_activity_timeline_component_spec.rb.
RSpec.describe NeoActivityComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation:) }
  let(:ticket) { create(:ticket, project:, organisation:) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # The ticket-timeline row starts hidden (display: none) until the timeline
  # filter shows it, so every lookup here reads invisible nodes too.
  def line_text
    page.find('span.min-w-0.flex-1', visible: :all).text(:all).squish
  end

  it 'names a long summary change and keeps the texts in the disclosure' do
    activity = create(:activity, trackable: ticket, organisation:, actor: user, action: 'updated',
                                 key: 'ticket.updated',
                                 attribute_changes: { 'summary' => ['a' * 60, "**#{'b' * 60}**"] })

    render_inline(described_class.new(activity:, ticket:))

    expect(line_text).to eq('Zusammenfassung geändert')
    expect(page).to have_css('summary', text: 'Unterschied ansehen', visible: :all)
    expect(page).to have_css('dd .md-preview strong', text: 'b' * 60, visible: :all)
    expect(page).not_to have_css('.line-through', visible: :all)
  end

  it 'keeps a short title change in the line, without a disclosure' do
    activity = create(:activity, trackable: ticket, organisation:, actor: user, action: 'title_changed',
                                 parameters: { 'from_title' => 'Logo', 'to_title' => 'Logo einsetzen' })

    render_inline(described_class.new(activity:, ticket:))

    expect(line_text).to eq('Titel Logo → Logo einsetzen')
    expect(page).to have_css('span.line-through', text: 'Logo', visible: :all)
    expect(page).not_to have_css('details', visible: :all)
  end
end
