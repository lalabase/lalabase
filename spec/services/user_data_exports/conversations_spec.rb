# frozen_string_literal: true

require 'rails_helper'

# What: what the personal data export says about conversations. The dates of the
#   messages a person wrote and of their own participations, and nothing else.
# Why: a conversation holds other people's words. A title may be somebody else's, a
#   text is not inventory, and an id of a conversation or of another person would tell
#   who talked to whom. A person who no longer takes part still gets what they wrote:
#   the export lists rows by their user_id, not through the read rule.
RSpec.describe 'Conversations in the personal data export', :ci_guard do
  let(:organisation) { create(:organisation, name: 'Nord GmbH') }
  let(:person) { member_of(organisation) }
  let(:colleague) { member_of(organisation) }
  let(:conversation) do
    ActsAsTenant.with_tenant(organisation) { create(:conversation, creator: colleague, title: 'Geheimes Angebot') }
  end

  let(:registry) { UserDataExports::Registry }
  let(:posts_source) { registry::SOURCES.find { |source| source.key == :conversation_posts } }
  let(:participations_source) { registry::SOURCES.find { |source| source.key == :conversation_participations } }

  after { ActsAsTenant.current_tenant = nil }

  def member_of(org)
    user = create(:user)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, role: create(:role, organisation: org), active: true)
    end
    User.find(user.id)
  end

  def take_part(user, **attributes)
    ActsAsTenant.with_tenant(organisation) do
      create(:conversation_participant, conversation: conversation, user: user, **attributes)
    end
  end

  def write(user, text, at:)
    ActsAsTenant.with_tenant(organisation) do
      create(:conversation_post, conversation: conversation, user: user, content: text, created_at: at)
    end
  end

  def folder
    "organisations/#{organisation.name.parameterize}-#{organisation.id.to_s.first(8)}"
  end

  def exported(user, file)
    JSON.parse(UserDataExports::Builder.new(User.find(user.id)).files.fetch("#{folder}/#{file}"))
  end

  describe 'the registry entries' do
    it 'lists the posts of a person as a tenant scoped source with the date alone' do
      expect(posts_source.model).to eq(ConversationPost)
      expect(posts_source.tenant_scoped).to be(true)
      expect(posts_source.exported_keys).to eq(%w[created_at])
    end

    it 'lists the participations of a person as a tenant scoped source with two dates' do
      expect(participations_source.model).to eq(ConversationParticipant)
      expect(participations_source.tenant_scoped).to be(true)
      expect(participations_source.exported_keys).to eq(%w[created_at archived_at])
    end

    it 'leaves the conversations themselves out, with a reason' do
      expect(registry::EXCLUDED.fetch('conversations')).to include('creator_id', 'title')
      expect(registry.covered_tables).to include('conversation_posts', 'conversation_participants')
      expect(registry.covered_tables).not_to include('conversations')
    end

    it 'exports no title, no text, no id of a conversation and no id of a person' do
      keys = posts_source.exported_keys + participations_source.exported_keys

      expect(keys.grep(/title|content|text|body|_id\z|\Aid\z|name|event/)).to be_empty
    end
  end

  describe 'the posts source' do
    it "lists the person's own messages, not a colleague's and not their own system entries" do
      take_part(person)
      take_part(colleague)
      own = write(person, 'Meine Nachricht', at: Time.utc(2026, 11, 2, 9, 0))
      write(colleague, 'Die Antwort der Kollegin', at: Time.utc(2026, 11, 2, 10, 0))
      entry = ActsAsTenant.with_tenant(organisation) do
        create(:conversation_post, :system, conversation: conversation, user: person)
      end

      rows = ActsAsTenant.with_tenant(organisation) { posts_source.scope.call(person).to_a }

      expect(entry.user_id).to eq(person.id)
      expect(rows).to contain_exactly(own)
    end
  end

  describe 'the participations source' do
    it "lists the person's own rows only" do
      own = take_part(person)
      take_part(colleague)

      rows = ActsAsTenant.with_tenant(organisation) { participations_source.scope.call(person).to_a }

      expect(rows).to contain_exactly(own)
    end
  end

  describe 'the files of the export' do
    it 'holds an empty list in both files for a person without rows' do
      take_part(colleague)
      write(colleague, 'Eine Nachricht der Kollegin', at: Time.utc(2026, 11, 2, 10, 0))

      expect(exported(person, 'conversation_posts.json')).to eq([])
      expect(exported(person, 'conversation_participations.json')).to eq([])
      expect(exported(colleague, 'conversation_posts.json').size).to eq(1)
    end

    it 'holds the dates and nothing else' do
      take_part(person, archived_at: Time.utc(2026, 11, 5, 8, 0))
      take_part(colleague)
      write(person, 'Sehr vertraulicher Text', at: Time.utc(2026, 11, 2, 9, 0))
      write(colleague, 'Die Antwort der Kollegin', at: Time.utc(2026, 11, 2, 10, 0))
      files = UserDataExports::Builder.new(User.find(person.id)).files
      posts = JSON.parse(files.fetch("#{folder}/conversation_posts.json"))
      participations = JSON.parse(files.fetch("#{folder}/conversation_participations.json"))
      everything = files.reject { |name, _| name.start_with?('avatar') }.values.join

      expect(posts.map(&:keys)).to eq([%w[created_at]])
      expect(Time.zone.parse(posts.first['created_at'])).to eq(Time.utc(2026, 11, 2, 9, 0))
      expect(participations.map(&:keys)).to eq([%w[created_at archived_at]])
      expect(Time.zone.parse(participations.first['archived_at'])).to eq(Time.utc(2026, 11, 5, 8, 0))
      expect(everything).to include(person.email)
      expect(everything).not_to include('Geheimes Angebot', 'Sehr vertraulicher Text', 'Die Antwort der Kollegin',
                                        conversation.id, colleague.id)
    end

    it 'still gives a person who no longer takes part the dates of what they wrote, and no participation' do
      row = take_part(person)
      write(person, 'Vor dem Abschied', at: Time.utc(2026, 11, 2, 9, 0))
      expect(exported(person, 'conversation_participations.json').size).to eq(1)

      ActsAsTenant.with_tenant(organisation) { row.destroy! }

      expect(ActsAsTenant.with_tenant(organisation) { Conversation.visible_to(User.find(person.id)) }).to be_empty
      expect(exported(person, 'conversation_posts.json').size).to eq(1)
      expect(exported(person, 'conversation_participations.json')).to eq([])
    end

    # The boundary of the whole export, not of these two sources: it covers the
    # organisations a person still has a membership row in.
    it 'gives a deactivated member the dates still, and somebody removed from the organisation nothing of it' do
      take_part(person)
      write(person, 'Vor der Deaktivierung', at: Time.utc(2026, 11, 2, 9, 0))
      membership = Membership.find_by!(user_id: person.id, organisation_id: organisation.id)

      membership.update!(active: false)
      expect(exported(person, 'conversation_posts.json').size).to eq(1)

      membership.destroy!
      files = UserDataExports::Builder.new(User.find(person.id)).files

      expect(files.keys.grep(/conversation/)).to be_empty
      expect(ActsAsTenant.with_tenant(organisation) { ConversationPost.where(user_id: person.id).count }).to eq(1)
    end

    it 'keeps the rows of one organisation out of the folder of another' do
      elsewhere = create(:organisation, name: 'Süd AG')
      ActsAsTenant.with_tenant(elsewhere) do
        create(:membership, user: person, organisation: elsewhere, role: create(:role, organisation: elsewhere))
      end
      take_part(person)
      write(person, 'Nur in der Nord GmbH', at: Time.utc(2026, 11, 2, 9, 0))
      files = UserDataExports::Builder.new(User.find(person.id)).files
      other_folder = "organisations/#{elsewhere.name.parameterize}-#{elsewhere.id.to_s.first(8)}"

      expect(JSON.parse(files.fetch("#{folder}/conversation_posts.json")).size).to eq(1)
      expect(JSON.parse(files.fetch("#{other_folder}/conversation_posts.json"))).to eq([])
      expect(JSON.parse(files.fetch("#{other_folder}/conversation_participations.json"))).to eq([])
    end
  end
end
