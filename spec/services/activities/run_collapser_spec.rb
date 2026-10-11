# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Activities::RunCollapser do
  let(:actor) { build_stubbed(:user) }
  let(:organisation) { build_stubbed(:organisation) }
  let(:project) { build_stubbed(:project, organisation:) }
  let(:ticket) { build_stubbed(:ticket, project:, organisation:) }
  let(:other_ticket) { build_stubbed(:ticket, project:, organisation:) }
  let(:start) { Time.zone.local(2026, 9, 2, 18, 29) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def activity(action, at:, trackable: ticket)
    build_stubbed(:activity, action:, actor:, trackable:, organisation:, created_at: at,
                             parameters: { 'display_name' => 'Ticket' })
  end

  it 'collapses different fields on one object while another object interleaves' do
    status = activity('status_changed', at: start)
    foreign = activity('priority_changed', at: start + 1.minute, trackable: other_ticket)
    priority = activity('priority_changed', at: start + 2.minutes)
    title = activity('title_changed', at: start + 3.minutes)

    items = described_class.for_project([title, priority, foreign, status])
    run = items.find { |item| item.is_a?(described_class::ActivityRun) }

    expect(run.activities).to contain_exactly(status, priority, title)
    expect(run.field).to eq(:multiple)
    expect(items).to include(foreign)
  end

  it 'does not collapse changes on different objects' do
    first = activity('status_changed', at: start)
    second = activity('status_changed', at: start + 1.minute, trackable: other_ticket)

    expect(described_class.for_project([second, first])).to eq([second, first])
  end

  it 'lets a non-change on the same object split a project run' do
    status = activity('status_changed', at: start)
    comment = activity('post_added', at: start + 1.minute)
    priority = activity('priority_changed', at: start + 2.minutes)

    expect(described_class.for_project([priority, comment, status])).to eq([priority, comment, status])
  end

  it 'does not collapse project changes across a day boundary' do
    previous_day = activity('status_changed', at: start.end_of_day - 1.minute)
    next_day = activity('priority_changed', at: start.end_of_day + 1.minute)

    expect(described_class.for_project([next_day, previous_day])).to eq([next_day, previous_day])
  end

  it 'keeps the ticket timeline strict to adjacent same-field changes' do
    status = activity('status_changed', at: start)
    priority = activity('priority_changed', at: start + 1.minute)

    expect(described_class.for_ticket([status, priority])).to eq([status, priority])
  end
end
