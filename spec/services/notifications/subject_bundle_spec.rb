# frozen_string_literal: true

require 'rails_helper'

# The rule both inbox actors share: which rows of a person an action may touch
# in ONE organisation, and which rows a chosen row brings along. The actors'
# specs hold the writes; here stands what must not depend on the caller: the
# organisation is the one that is NAMED, whatever tenant the caller runs under.
RSpec.describe Notifications::SubjectBundle, :ci_guard do
  let(:user) { create(:user) }
  let(:north) { create(:organisation) }
  let(:south) { create(:organisation) }
  let(:north_project) { ActsAsTenant.with_tenant(north) { create(:project, organisation: north) } }

  def system_row(org)
    ActsAsTenant.with_tenant(org) do
      create(:notification, recipient: user, organisation: org, project: nil, channel: 'in_app', state: :delivered)
    end
  end

  before do
    Prosopite.pause
    make_token_owner_a_member(user, north, projects: [north_project])
    make_token_owner_a_member(user, south)
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  # A row without a project passes the rule of what a person may see in ANY
  # organisation (a system message belongs to no project). Without the named
  # organisation a caller that runs outside a tenant would reach it.
  it 'answers the rows of the named organisation only, even for a caller without a tenant' do
    mine = system_row(north)
    elsewhere = system_row(south)

    found = ActsAsTenant.without_tenant { described_class.visible(user: user, organisation: north).pluck(:id) }

    expect(found).to eq([mine.id])
    expect(found).not_to include(elsewhere.id)
  end

  it 'locks the chosen rows with the in-app rows about their subjects, and answers nothing else' do
    ticket, other = ActsAsTenant.with_tenant(north) { create_list(:ticket, 2, project: north_project) }
    rows = ActsAsTenant.with_tenant(north) do
      [ticket, ticket, other].map do |subject|
        create(:notification, recipient: user, organisation: north, project: north_project, notifiable: subject,
                              channel: 'in_app', state: :delivered)
      end
    end
    mail = ActsAsTenant.with_tenant(north) do
      create(:notification, recipient: user, organisation: north, project: north_project, notifiable: ticket,
                            channel: 'email', state: :delivered)
    end

    locked = ActsAsTenant.with_tenant(north) do
      visible = described_class.visible(user: user, organisation: north)
      Notification.transaction { described_class.lock(visible: visible, chosen: visible.where(id: rows.first.id)).pluck(:id) }
    end

    expect(locked).to contain_exactly(rows[0].id, rows[1].id)
    expect(locked).not_to include(mail.id, rows[2].id)
  end
end
