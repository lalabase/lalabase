# frozen_string_literal: true

require 'rails_helper'

# The one write behind the bulk bar of both inboxes: a selection of rows is
# marked read or archived, in every organisation it touches. The request specs
# (inbox_bulk_actions_spec, all_inboxes_bulk_actions_spec) hold what a reader
# sees; here stands what the actor itself promises a caller, whatever ids the
# caller hands over.
RSpec.describe Actors::ChangeNotificationStates do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }
  let(:north_project) { project_in(north) }
  let(:south_project) { project_in(south) }
  let(:north_ticket) { ticket_in(north, north_project) }
  let(:south_ticket) { ticket_in(south, south_project) }

  def project_in(org)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org) }
  end

  def ticket_in(org, project)
    ActsAsTenant.with_tenant(org) { create(:ticket, project: project) }
  end

  def row(org, project, ticket, recipient: user, state: :delivered, channel: 'in_app', archived_at: nil)
    ActsAsTenant.with_tenant(org) do
      create(:notification, recipient: recipient, organisation: org, project: project, notifiable: ticket,
                            event_type: 'ticket_commented', channel: channel, state: state,
                            read_at: %i[read archived].include?(state) ? 2.hours.ago : nil,
                            archived_at: archived_at || (state == :archived ? 2.hours.ago : nil))
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

  def change(selection, to)
    described_class.new(ids_by_organisation: selection, change: to, current_user: user).then do |actor|
      [actor.call, actor]
    end
  end

  def fresh(notification)
    ActsAsTenant.without_tenant { Notification.find(notification.id) }
  end

  def state_of(notification)
    fresh(notification).state
  end

  it 'marks the rows of two organisations read in one call, each with its whole subject' do
    north_row = row(north, north_project, north_ticket)
    north_sibling = row(north, north_project, north_ticket)
    south_row = row(south, south_project, south_ticket)
    untouched = row(south, south_project, ticket_in(south, south_project))

    result, actor = change({ north => [north_row.id], south => [south_row.id] }, 'read')

    expect(result).to be_success
    expect(result.resource).to be_nil
    expect([north_row, north_sibling, south_row].map { |n| state_of(n) }).to all(eq('read'))
    expect(fresh(north_sibling).read_at).to be_present
    expect(state_of(untouched)).to eq('delivered')
    expect(actor.changed_count).to eq(3)
  end

  it 'takes the whole subject of every selected row along, also of two tickets in one organisation' do
    first = row(north, north_project, north_ticket)
    first_sibling = row(north, north_project, north_ticket)
    other_ticket = ticket_in(north, north_project)
    second = row(north, north_project, other_ticket)
    second_sibling = row(north, north_project, other_ticket)
    third_ticket = ticket_in(north, north_project)
    third = row(north, north_project, third_ticket)
    third_sibling = row(north, north_project, third_ticket)

    _, actor = change({ north => [first.id, second.id, third.id] }, 'archive')

    expect([first, first_sibling, second, second_sibling, third, third_sibling].map { |n| state_of(n) }).to all(eq('archived'))
    expect(actor.changed_count).to eq(6)
  end

  it 'archives the selection, read or not, with the whole subject' do
    unread = row(north, north_project, north_ticket)
    read_sibling = row(north, north_project, north_ticket, state: :read)

    _, actor = change({ north => [unread.id] }, 'archive')

    expect([unread, read_sibling].map { |n| state_of(n) }).to all(eq('archived'))
    expect(fresh(unread).archived_at).to be_present
    expect(actor.changed_count).to eq(2)
  end

  it 'leaves a sibling that is already archived as it was' do
    selected = row(north, north_project, north_ticket)
    archived = row(north, north_project, north_ticket, state: :archived, archived_at: 3.days.ago)
    before = fresh(archived).archived_at

    _, actor = change({ north => [selected.id] }, 'archive')

    expect(fresh(archived).archived_at).to eq(before)
    expect(actor.changed_count).to eq(1)
  end

  it 'reads only what is unread: a read row keeps its time, an archived one stays in the archive' do
    read = row(north, north_project, north_ticket, state: :read)
    archived = row(north, north_project, north_ticket, state: :archived)
    read_at = fresh(read).read_at

    _, actor = change({ north => [read.id, archived.id] }, 'read')

    expect(fresh(read).read_at).to eq(read_at)
    expect(state_of(archived)).to eq('archived')
    expect(actor.changed_count).to eq(0)
  end

  it 'changes nothing the second time' do
    selected = row(north, north_project, north_ticket)
    change({ north => [selected.id] }, 'archive')
    archived_at = fresh(selected).archived_at

    result, actor = change({ north => [selected.id] }, 'archive')

    expect(result).to be_success
    expect(actor.changed_count).to eq(0)
    expect(fresh(selected).archived_at).to eq(archived_at)
  end

  describe 'what it does not write, whatever the caller hands over' do
    it 'leaves the notification of another person about the same ticket' do
      colleague = create(:user)
      make_token_owner_a_member(colleague, north, projects: [north_project])
      mine = row(north, north_project, north_ticket)
      theirs = row(north, north_project, north_ticket, recipient: colleague)

      change({ north => [mine.id, theirs.id] }, 'archive')

      expect(state_of(mine)).to eq('archived')
      expect(state_of(theirs)).to eq('delivered')
    end

    it 'leaves the mail row about the same ticket, selected or not' do
      mine = row(north, north_project, north_ticket)
      mail = row(north, north_project, north_ticket, channel: 'email')
      other_mail = row(north, north_project, ticket_in(north, north_project), channel: 'email')

      change({ north => [mine.id, other_mail.id] }, 'read')

      expect(state_of(mine)).to eq('read')
      expect([mail, other_mail].map { |n| state_of(n) }).to all(eq('delivered'))
    end

    it 'does not widen from a selected mail row to the in-app rows of its ticket' do
      in_app = row(north, north_project, north_ticket)
      mail = row(north, north_project, north_ticket, channel: 'email')

      _, actor = change({ north => [mail.id] }, 'archive')

      expect(state_of(in_app)).to eq('delivered')
      expect(actor.changed_count).to eq(0)
    end

    it 'leaves a row in a project the person may not read' do
      hidden_project = project_in(north)
      hidden = row(north, hidden_project, ticket_in(north, hidden_project))
      mine = row(north, north_project, north_ticket)

      change({ north => [hidden.id, mine.id] }, 'archive')

      expect(state_of(hidden)).to eq('delivered')
      expect(state_of(mine)).to eq('archived')
    end

    it 'reads an id only in the organisation it was handed over for' do
      south_row = row(south, south_project, south_ticket)

      _, actor = change({ north => [south_row.id] }, 'archive')

      expect(state_of(south_row)).to eq('delivered')
      expect(actor.changed_count).to eq(0)
    end
  end

  it 'refuses a change it does not offer and writes nothing' do
    selected = row(north, north_project, north_ticket, state: :archived)

    result, = change({ north => [selected.id] }, 'unarchive')

    expect(result).not_to be_success
    expect(result.code).to eq(:invalid_input)
    expect(state_of(selected)).to eq('archived')
  end

  it 'rolls the first organisation back when the second fails' do
    north_row = row(north, north_project, north_ticket)
    south_row = row(south, south_project, south_ticket)
    first, second = [north, south].sort_by(&:id)
    allow(Notifications::SubjectBundle).to receive(:lock).and_wrap_original do |original, **kwargs|
      raise Actors::ActorError, 'the second organisation fails' if ActsAsTenant.current_tenant == second

      original.call(**kwargs)
    end

    result, = change({ second => [(second == north ? north_row : south_row).id],
                       first => [(first == north ? north_row : south_row).id] }, 'archive')

    expect(result).not_to be_success
    expect([north_row, south_row].map { |n| state_of(n) }).to all(eq('delivered'))
  end

  it 'works through the organisations in the order of their ids, each under its own tenant' do
    north_row = row(north, north_project, north_ticket)
    south_row = row(south, south_project, south_ticket)
    seen = []
    allow(Notifications::SubjectBundle).to receive(:lock).and_wrap_original do |original, **kwargs|
      seen << ActsAsTenant.current_tenant
      original.call(**kwargs)
    end

    change({ south => [south_row.id], north => [north_row.id] }, 'read')

    expect(seen).to eq([north, south].sort_by(&:id))
    expect(ActsAsTenant.current_tenant).to be_nil
  end
end
