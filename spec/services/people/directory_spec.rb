# frozen_string_literal: true

require 'rails_helper'

RSpec.describe People::Directory, :ci_guard do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*actions, title: nil)
    role = create(:role, organisation: organisation, **{ title: title }.compact)
    actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
    role
  end

  def member(first, last, role: role_with, active: true)
    user = create(:user, first_name: first, last_name: last)
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    User.find(user.id)
  end

  let(:project) { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }
  let(:viewer) { member('Vera', 'Viewer', role: role_with('view_people')) }
  let(:admin) { member('Anna', 'Admin', role: role_with(title: Role::ACCOUNT_ADMIN_TITLE)) }
  let(:colleague) { member('Carl', 'Kollege') }
  let(:stranger) { member('Sven', 'Fremd') }
  let!(:contact) { create(:person, organisation: organisation, name: 'Doris Dienstleister', company: 'Hosting AG') }

  before do
    create(:project_permission, user: viewer, project: project, tickets_access: :read_only)
    create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
    create(:project_permission, user: stranger, project: other_project, tickets_access: :read_only)
  end

  def entries(user = viewer, **options)
    described_class.new(viewer: user, organisation: organisation, **options).entries
  end

  def names(list)
    list.map { |entry| entry.person&.name || entry.user.display_name }
  end

  it 'lists the visible members and the contacts, sorted by name' do
    expect(names(entries)).to eq(['Carl Kollege', 'Doris Dienstleister', 'Vera Viewer'])
  end

  it 'follows MembershipPolicy::Scope: a member of a foreign project is absent for a non-admin' do
    create(:person, organisation: organisation, user: stranger, name: 'Sven Fremd', phone: '1')

    expect(names(entries)).not_to include('Sven Fremd')
    expect(names(entries(admin))).to include('Sven Fremd')
  end

  it 'attaches the person row of a member' do
    row = create(:person, organisation: organisation, user: colleague, name: 'Carl Kollege', function: 'Admin')

    entry = entries.find { |item| item.user == colleague }
    expect(entry).to be_member
    expect(entry.person).to eq(row)
  end

  it 'shows a row linked to a deactivated member as a contact' do
    row = create(:person, organisation: organisation, user: colleague, name: 'Carl Kollege')
    Membership.find_by(user: colleague, organisation: organisation).update!(active: false)

    list = entries
    expect(list.find { |item| item.person == row }.kind).to eq(:contact)
    expect(list.count { |item| item.user == colleague }).to eq(0)
  end

  # One directory per example: each call resolves the viewer's reach once, and
  # Prosopite would read a second call as an N+1.
  {
    'members' => ['Carl Kollege', 'Vera Viewer'],
    'contacts' => ['Doris Dienstleister'],
    'nonsense' => ['Carl Kollege', 'Doris Dienstleister', 'Vera Viewer']
  }.each do |kind, expected|
    it "filters by kind #{kind}" do
      expect(names(entries(kind: kind))).to eq(expected)
    end
  end

  {
    'hosting' => ['Doris Dienstleister'],
    'mueller' => ['Jürgen Müller'],
    'Müller' => ['Jürgen Müller'],
    'kollege' => ['Carl Kollege'],
    'zzz' => []
  }.each do |query, expected|
    it "searches the fields umlaut-insensitive (#{query})" do
      create(:person, organisation: organisation, name: 'Jürgen Müller', company: nil)

      expect(names(entries(query: query))).to eq(expected)
    end
  end

  it 'returns nothing without the right' do
    expect(entries(colleague)).to be_empty
  end
end
