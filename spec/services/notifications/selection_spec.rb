# frozen_string_literal: true

require 'rails_helper'

# The lookup behind a bulk action of the inbox above the organisations
# (Actors::ChangeNotificationStates): the rows of a selection per organisation,
# and only rows the person may act on. It crosses organisations on ids a browser
# sends and still never leaves the tenant: every read runs under the tenant of
# one organisation the person is an active member of.
RSpec.describe Notifications::Selection, :ci_guard do
  let(:user) { create(:user) }
  let(:stranger) { create(:user) }
  let(:north) { create(:organisation) }
  let(:south) { create(:organisation) }
  let(:elsewhere) { create(:organisation) }
  let(:north_project) { project_in(north) }
  let(:south_project) { project_in(south) }

  def project_in(org)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org) }
  end

  def row(org, project, **attributes)
    ActsAsTenant.with_tenant(org) do
      create(:notification, { recipient: user, organisation: org, project: project,
                              notifiable: create(:ticket, project: project), channel: 'in_app', state: :delivered }.merge(attributes))
    end
  end

  before do
    Prosopite.pause
    make_token_owner_a_member(user, north, projects: [north_project])
    make_token_owner_a_member(user, south, projects: [south_project])
  end

  after do
    ActsAsTenant.current_tenant = nil
    Prosopite.resume
  end

  let!(:north_row) { row(north, north_project) }
  let!(:north_archived) { row(north, north_project, state: :archived, archived_at: 1.hour.ago) }
  let!(:south_row) { row(south, south_project) }

  def found(ids)
    described_class.call(user: user, ids: ids)
  end

  it 'answers the ids per organisation, read and archived rows included' do
    read = row(south, south_project, state: :read, read_at: 1.hour.ago)

    expect(found([north_row.id, north_archived.id, south_row.id, read.id]))
      .to eq(north => [north_row.id, north_archived.id].sort, south => [south_row.id, read.id].sort)
  end

  it 'names the organisations in the order of their ids, and none it found nothing in' do
    expect(found([south_row.id, north_row.id]).keys).to eq([north, south].sort_by(&:id))
    expect(found([south_row.id]).keys).to eq([south])
  end

  it 'drops what is no row of this inbox, without a word' do
    theirs = row(north, north_project, recipient: stranger)
    mail = row(north, north_project, channel: 'email')
    hidden_project = project_in(south)
    hidden = row(south, hidden_project)
    foreign = ActsAsTenant.with_tenant(elsewhere) { row(elsewhere, project_in(elsewhere)) }

    expect(found([theirs.id, mail.id, hidden.id, foreign.id, SecureRandom.uuid, north_row.id]))
      .to eq(north => [north_row.id])
  end

  # A row without a project (a system message) passes the rule of what a person
  # may see in an organisation whatever their rights there, so the membership is
  # the gate: only organisations the person is an ACTIVE member of are asked.
  it 'drops the rows of an organisation the person has left, those without a project too' do
    system_message = ActsAsTenant.with_tenant(south) do
      create(:notification, recipient: user, organisation: south, project: nil, channel: 'in_app', state: :delivered)
    end
    expect(found([system_message.id])).to eq(south => [system_message.id])

    Membership.find_by(user_id: user.id, organisation_id: south.id).update!(active: false)

    expect(found([north_row.id, south_row.id, system_message.id])).to eq(north => [north_row.id])
  end

  it 'reads a malformed id, a doubled one and something that is no id as nothing' do
    expect(found(['not-an-id', nil, '', { 'a' => 'b' }, [north_row.id], 7])).to eq({})
    expect(found([north_row.id, north_row.id.upcase, north_row.id])).to eq(north => [north_row.id])
    expect(found(nil)).to eq({})
    expect(found(north_row.id)).to eq(north => [north_row.id])
  end

  it 'asks the database nothing when no usable id is left' do
    user # built before the count starts
    queries = 0
    counter = ActiveSupport::Notifications.subscribe('sql.active_record') { queries += 1 }

    found(['not-an-id'])

    expect(queries).to eq(0)
  ensure
    ActiveSupport::Notifications.unsubscribe(counter)
  end

  # The rule this lookup exists for: no read with the tenant lifted. A read of
  # notifications outside a tenant would raise here (require_tenant), and one
  # inside without_tenant is what the lookup must not need.
  it 'reads notifications only under the tenant of an organisation the person belongs to' do
    tenants = []
    counter = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      tenants << ActsAsTenant.current_tenant if payload[:sql].include?('FROM "notifications"')
    end
    allow(ActsAsTenant).to receive(:without_tenant).and_call_original

    found([north_row.id, south_row.id])

    expect(tenants).to contain_exactly(north, south)
    expect(ActsAsTenant).not_to have_received(:without_tenant)
  ensure
    ActiveSupport::Notifications.unsubscribe(counter)
  end
end
