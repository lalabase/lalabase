# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Demo::World do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 11, 4, 9, 0) }
  let(:password) { 'demo-password-for-the-spec' }
  let(:fiction) { Lalabase::Demo::Fiction }

  # A seeder writes one record after another through the services a request uses
  # once; the repeated lookups that follow are not a page's N+1.
  def build(**options)
    Prosopite.pause do
      travel_to(now) { described_class.new(locale: :en, now: now, password: password, **options).build }
    end
  end

  describe 'the world it builds' do
    let!(:world) { build }
    let(:organisation) { world.organisation }

    around { |example| ActsAsTenant.without_tenant { example.run } }

    it 'holds the people, projects and records of the fiction' do
      expect(organisation.name).to eq(described_class::ORGANISATION_NAME)
      expect(organisation.users.pluck(:email)).to match_array(fiction::PEOPLE.keys.map { fiction.email(_1) })
      expect(organisation.projects.pluck(:name)).to match_array(fiction::PROJECTS.values.map { _1[:en] })
      expect(world.project(:deichblick).tickets.order(:created_at).pluck(:title)).to eq(fiction::TICKETS.map { _1[:en] })
      expect(TimeSession.where(organisation: organisation).count).to eq(fiction::TIME.size)
      expect(world.notes.map(&:title)).to eq(fiction::NOTES.map { _1[:en] })
      expect(world.ticket(fiction::CHAT[:ticket]).posts.count).to eq(fiction::COMMENTS.size)
      expect(world.chat.chatposts.count).to eq(2)
    end

    # The demo signs a visitor in as this person: every right of the team, none of
    # the account.
    it 'gives the signed-in person the team role, not the account admin role' do
      signed_in = world.signed_in
      expect(signed_in.email).to eq(fiction.email(fiction::SIGNED_IN))
      expect(signed_in.role_in_organisation(organisation)).not_to be_account_admin
      expect(world.person(fiction::OWNER).role_in_organisation(organisation)).to be_account_admin
      expect(signed_in.has_permission_in_organisation?(organisation, 'assistant', 'use_assistant')).to be(true)
      expect(signed_in.can_access_project?(world.project(:faehrhaus), :write, :tickets)).to be(true)
    end

    # The time list is the first thing that went missing without the admin role.
    it 'lets the signed-in person see everybody\'s hours, and the others their own' do
      expect(TimeSessions::ViewingScope.call(user: world.signed_in, project: world.project(:deichblick)).tier)
        .to eq(:all)
      expect(TimeSessions::ViewingScope.call(user: world.person(:ole), project: world.project(:deichblick)).tier)
        .to eq(:own)
    end

    it 'lets every person sign in with the given password, confirmed' do
      organisation.users.each do |user|
        expect(user.valid_password?(password)).to be(true)
        expect(user).to be_confirmed
      end
    end

    it 'adds one meeting with its summary and one waiting for it, with guests among the participants' do
      with_summary, without_summary = world.meetings
      expect(with_summary.generated_summary).to include('Damage report')
      expect(without_summary.generated_summary).to be_blank
      expect(without_summary.summary_source).to be_present
      expect(with_summary.meeting_participants.pluck(:display_name, :user_id))
        .to contain_exactly(['Svenja Brandt', world.person(:svenja).id], ['Ole Jensen', world.person(:ole).id],
                            ['Kerstin Möller', nil])
    end

    # A text names its dates from the moment of the build, so a world built today
    # does not speak of an acceptance six months ago.
    it 'fills the dates of its texts from the moment it is built' do
      expect(world.notes.first.content.to_s).to include('Acceptance with Deichblick Immobilien on 27 October')
      expect(world.chat.chatposts.find_by(role: 'assistant').content).to include('acceptance record of 27 October')
      expect(world.notes.first.content.to_s + world.chat.chatposts.map(&:content).join).not_to include('%<')
    end

    it 'dates its records back from the moment it is built' do
      expect(world.ticket(0).created_at).to eq(now - (fiction::TICKETS.size * 3).days)
      expect(TimeSession.where(organisation: organisation).maximum(:occurred_on).to_date).to eq(now.to_date)
    end

    it 'leaves the assistant search off unless asked' do
      expect(world.notes.map(&:create_embeddings)).to all(be(false))
      expect(world.meetings.map(&:create_embeddings)).to all(be(false))
    end
  end

  # The stored answer speaks of "4:30 hours this week". Built on a Monday at the hour
  # of the nightly reset, a booking two days back would land in the week before, and
  # the time list and the answer would contradict each other.
  it 'keeps every booking in the week of the build, so the stored answer adds up on a Monday' do
    monday = Time.zone.local(2026, 10, 19, 3, 0)
    world = Prosopite.pause do
      travel_to(monday) { described_class.new(locale: :en, now: monday, password: password).build }
    end
    ActsAsTenant.without_tenant do
      sessions = TimeSession.where(organisation: world.organisation)
      expect(sessions.pluck(:occurred_on)).to all(be_between(monday.beginning_of_week, monday))
      ole_on_the_statement = sessions.where(creator: world.person(:ole), ticket: world.ticket(fiction::CHAT[:ticket]))
      expect(ole_on_the_statement.sum(:duration)).to eq(270)
      expect(world.chat.chatposts.find_by(role: 'assistant').content).to include('4:30 hours on it this week')
    end
  end

  it 'marks notes, comments and meetings for the search when asked' do
    world = build(embeddings: true)
    ActsAsTenant.without_tenant do
      expect(world.notes.map(&:create_embeddings)).to all(be(true))
      expect(world.meetings.map(&:create_embeddings)).to all(be(true))
      expect(Post.where(organisation: world.organisation).pluck(:create_embeddings)).to all(be(true))
    end
  end

  it 'passes extra attributes to the organisation' do
    world = build(organisation: { assistant_enabled: true, ai_enabled: true })
    expect(world.organisation.reload).to have_attributes(assistant_enabled: true, ai_enabled: true)
  end

  # The demo builds this world in production, where the test group of the bundle is
  # not installed. A tripwire, not a proof: it reads the source.
  it 'uses no factories' do
    code = Rails.root.join('lib/lalabase/demo/world.rb').readlines.grep_v(/\A\s*#/).join
    expect(code).to include('Actors::SaveTicket.call')
    expect(code).not_to match(/FactoryBot|\bcreate\(:|\bbuild\(:/)
  end
end
