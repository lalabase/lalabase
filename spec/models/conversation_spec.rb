# frozen_string_literal: true

require 'rails_helper'

# What: who reads a conversation. One rule, Conversation.visible_to: a participant row
#   AND an active membership in the conversation's organisation. Its two other ends,
#   #visible_to? and #visible_participants, and ConversationPost.visible_to answer the same.
# Why: a conversation holds correspondence with a client. No right on a project and no
#   admin role opens it, and somebody who was deactivated or removed reads nothing.
# How the examples are built: a refusal is only believed next to a yes. Each example that
#   says "sees nothing" first shows the same person seeing a conversation, so an empty
#   answer cannot come from broken test data. And a person is loaded fresh after their
#   membership changed: User#active_member_of_organisation? remembers a yes.
RSpec.describe Conversation, :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:creator) { member_of(organisation) }
  let(:conversation) { create(:conversation, creator: creator) }
  let(:second_conversation) { create(:conversation, creator: creator, title: 'Rückfrage zur Rechnung') }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_in(org, **attributes)
    ActsAsTenant.with_tenant(org) { create(:role, organisation: org, **attributes) }
  end

  # A person with a membership in the organisation, loaded fresh.
  def member_of(org, active: true, role: nil)
    user = create(:user)
    create(:membership, user: user, organisation: org, role: role || role_in(org), active: active)
    User.find(user.id)
  end

  def membership_of(user, org = organisation)
    Membership.find_by!(user_id: user.id, organisation_id: org.id)
  end

  def fresh(user)
    User.find(user.id)
  end

  def take_part(user, in_conversation = conversation)
    create(:conversation_participant, conversation: in_conversation, organisation: in_conversation.organisation,
                                      user: user)
  end

  # What the scope lists for the person. Beside it the predicate is asked for every
  # conversation of the tenant, and for a participant the list from the other end:
  # the three must give the same answer.
  def seen_by(user)
    listed = described_class.visible_to(user).to_a
    # One question per conversation is the point here, not an N+1 to report.
    Prosopite.pause do
      described_class.find_each do |each_conversation|
        expect(each_conversation.visible_to?(user)).to eq(listed.include?(each_conversation)),
                                                       "visible_to? disagrees with the scope for #{each_conversation.title}"
        next unless user && each_conversation.conversation_participants.exists?(user_id: user.id)

        expect(each_conversation.visible_participants.exists?(id: user.id)).to eq(listed.include?(each_conversation)),
                                                                               'visible_participants disagrees with the scope'
      end
    end
    listed
  end

  describe '.visible_to, the one read rule' do
    it 'shows a conversation to a participant who is an active member' do
      participant = member_of(organisation)
      take_part(participant)

      expect(seen_by(participant)).to contain_exactly(conversation)
    end

    it 'shows nothing of a conversation to an active member who does not take part in it' do
      member = member_of(organisation)
      take_part(member, second_conversation)
      conversation

      expect(seen_by(member)).to contain_exactly(second_conversation)
    end

    it 'shows nothing to an account admin who does not take part' do
      admin = member_of(organisation, role: role_in(organisation, title: Role::ACCOUNT_ADMIN_TITLE))
      take_part(admin, second_conversation)
      conversation

      expect(admin.account_admin_in?(organisation)).to be(true)
      expect(seen_by(admin)).to contain_exactly(second_conversation)
    end

    it 'shows nothing to a member with full access to the labelled project who does not take part' do
      project = create(:project, organisation: organisation)
      reader = member_of(organisation)
      create(:project_permission, user: reader, project: project, tickets_access: 'read_write',
                                  notes_access: 'read_write', chats_access: 'read_write',
                                  documents_access: 'read_write', members_access: 'read_write',
                                  documentation_access: 'read_write', meetings_access: 'read_write')
      labelled = create(:conversation, creator: creator, project: project, title: 'Zum Beispielprojekt')
      take_part(reader, second_conversation)

      expect(ProjectPolicy.new(reader, project).show?).to be(true)
      expect(labelled.project).to eq(project)
      expect(seen_by(reader)).to contain_exactly(second_conversation)
    end

    it 'shows nothing to a participant whose membership is deactivated, and shows it again once it is active' do
      participant = member_of(organisation)
      take_part(participant)
      expect(seen_by(participant)).to contain_exactly(conversation)

      membership_of(participant).update!(active: false)
      expect(seen_by(fresh(participant))).to be_empty

      membership_of(participant).update!(active: true)
      expect(seen_by(fresh(participant))).to contain_exactly(conversation)
    end

    it 'shows nothing to a participant whose membership is gone' do
      participant = member_of(organisation)
      row = take_part(participant)
      expect(seen_by(participant)).to contain_exactly(conversation)

      membership_of(participant).destroy!

      expect(described_class.where(id: conversation.id)).to exist
      expect(row.reload.user_id).to eq(participant.id)
      expect(seen_by(fresh(participant))).to be_empty
    end

    it 'shows nothing to somebody whose participant row is gone' do
      participant = member_of(organisation)
      row = take_part(participant)
      expect(seen_by(participant)).to contain_exactly(conversation)

      row.destroy!

      expect(fresh(participant).active_member_of_organisation?(organisation)).to be(true)
      expect(seen_by(fresh(participant))).to be_empty
    end

    it 'is empty for nobody, without an error' do
      take_part(creator)
      expect(seen_by(creator)).to contain_exactly(conversation)

      expect(seen_by(nil)).to be_empty
      expect(conversation.visible_to?(nil)).to be(false)
    end

    it 'shows under each tenant the conversations of that organisation only, and asks the membership there' do
      person = member_of(organisation)
      create(:membership, user: person, organisation: other_organisation, role: role_in(other_organisation))
      take_part(person)
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        there = create(:conversation, creator: member_of(other_organisation), title: 'In der anderen Organisation')
        take_part(person, there)
        there
      end

      expect(described_class.visible_to(fresh(person))).to contain_exactly(conversation)
      ActsAsTenant.with_tenant(other_organisation) do
        expect(described_class.visible_to(fresh(person))).to contain_exactly(foreign)
      end

      membership_of(person, organisation).update!(active: false)

      expect(fresh(person).active_member_of_organisation?(other_organisation)).to be(true)
      expect(seen_by(fresh(person))).to be_empty
      ActsAsTenant.with_tenant(other_organisation) do
        expect(described_class.visible_to(fresh(person))).to contain_exactly(foreign)
      end
    end

    it 'lists each conversation once and chains like any relation' do
      participant = member_of(organisation)
      colleague = member_of(organisation)
      take_part(participant)
      take_part(colleague)
      take_part(creator)
      take_part(participant, second_conversation)
      conversation.update!(last_post_at: 2.days.ago)
      second_conversation.update!(last_post_at: 1.day.ago)

      visible = described_class.visible_to(participant)

      expect(visible).to be_a(ActiveRecord::Relation)
      expect(visible.to_a).to contain_exactly(conversation, second_conversation)
      expect(visible.count).to eq(2)
      expect(visible.where(title: second_conversation.title)).to contain_exactly(second_conversation)
      expect(visible.order(last_post_at: :desc).to_a).to eq([second_conversation, conversation])
      expect(visible.merge(described_class.where(id: conversation.id))).to contain_exactly(conversation)
      expect(described_class.where(id: conversation.id).visible_to(colleague)).to contain_exactly(conversation)
      expect(described_class.where(id: second_conversation.id).visible_to(colleague)).to be_empty
    end
  end

  describe '#visible_participants, the same rule from the other end' do
    it 'is a relation of users: the participants who are active members now' do
      active = member_of(organisation)
      deactivated = member_of(organisation)
      removed = member_of(organisation)
      bystander = member_of(organisation)
      rows = [take_part(active)]
      rows << take_part(deactivated)
      rows << take_part(removed)
      membership_of(deactivated).update!(active: false)
      membership_of(removed).destroy!

      participants = conversation.visible_participants

      expect(participants).to be_a(ActiveRecord::Relation)
      expect(participants.klass).to eq(User)
      expect(participants).to contain_exactly(active)
      expect(participants).not_to include(bystander)
      expect(rows.map(&:user_id)).to contain_exactly(active.id, deactivated.id, removed.id)
      # For every participant row: in the list exactly when the scope shows the conversation.
      expect(described_class.visible_to(fresh(active)).exists?(conversation.id)).to be(true)
      expect(participants.exists?(id: active.id)).to be(true)
      expect(described_class.visible_to(fresh(deactivated)).exists?(conversation.id)).to be(false)
      expect(participants.exists?(id: deactivated.id)).to be(false)
      expect(described_class.visible_to(fresh(removed)).exists?(conversation.id)).to be(false)
      expect(participants.exists?(id: removed.id)).to be(false)
    end
  end

  describe 'ConversationPost.visible_to' do
    it 'lists the posts of the conversations the person reads, and no other' do
      participant = member_of(organisation)
      admin = member_of(organisation, role: role_in(organisation, title: Role::ACCOUNT_ADMIN_TITLE))
      take_part(participant)
      take_part(admin, second_conversation)
      post = create(:conversation_post, conversation: conversation, user: creator)
      elsewhere = create(:conversation_post, conversation: second_conversation, user: creator)

      expect(ConversationPost.visible_to(participant)).to contain_exactly(post)
      expect(ConversationPost.visible_to(admin)).to contain_exactly(elsewhere)
      expect(ConversationPost.visible_to(member_of(organisation))).to be_empty
      expect(ConversationPost.visible_to(nil)).to be_empty

      membership_of(participant).update!(active: false)

      expect(ConversationPost.visible_to(fresh(participant))).to be_empty
      expect(ConversationPost.visible_to(fresh(admin))).to contain_exactly(elsewhere)
    end
  end

  describe 'the tenant' do
    it 'raises on a read without a tenant' do
      conversation
      ActsAsTenant.current_tenant = nil

      expect { described_class.count }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
      expect { described_class.visible_to(creator).to_a }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
      expect { conversation.visible_to?(creator) }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
      expect { conversation.visible_participants.to_a }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
    end

    it 'does not find a conversation of another organisation' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:conversation, creator: member_of(other_organisation))
      end

      expect(ActsAsTenant.with_tenant(other_organisation) { described_class.exists?(foreign.id) }).to be(true)
      expect(described_class.where(id: foreign.id)).to be_empty
      expect(foreign.visible_to?(creator)).to be(false)
    end
  end

  describe 'the project, a label inside the same organisation' do
    let(:project) { create(:project, organisation: organisation) }
    let(:foreign_project) do
      ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
    end

    it 'takes a project of its own organisation, and none' do
      expect(create(:conversation, creator: creator, project: project).project).to eq(project)
      expect(create(:conversation, creator: creator, project: nil)).to be_persisted
    end

    # Twice over: the tenant check of a reference declared before acts_as_tenant, and
    # the model's own check, which also holds where no tenant is set.
    it 'refuses a project of another organisation under its own tenant' do
      record = build(:conversation, creator: creator, project_id: foreign_project.id)

      expect(record).not_to be_valid
      expect(record.errors[:project_id]).to include('association is invalid [ActsAsTenant]')
      expect(record.errors.added?(:project, :invalid)).to be(true)
      expect { record.save! }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'refuses it as well when no tenant is set' do
      ActsAsTenant.without_tenant do
        fine = described_class.new(organisation: organisation, creator: creator, project_id: project.id)
        record = described_class.new(organisation: organisation, creator: creator, project_id: foreign_project.id)

        expect(fine).to be_valid
        expect(record).not_to be_valid
        expect(record.errors.added?(:project, :invalid)).to be(true)
      end
    end

    it 'refuses it as well under the other tenant, which stamps the row as its own' do
      own_project_id = project.id
      expect(project.organisation_id).to eq(organisation.id)

      ActsAsTenant.with_tenant(other_organisation) do
        record = build(:conversation, creator: creator, project_id: own_project_id)

        expect(record).not_to be_valid
        expect(record.organisation_id).to eq(other_organisation.id)
        expect(record.errors.added?(:project, :invalid)).to be(true)
      end
    end

    it 'keeps the conversation and empties the label when the project row is deleted' do
      labelled = create(:conversation, creator: creator, project: project)

      Project.where(id: project.id).delete_all

      expect(labelled.reload.project_id).to be_nil
    end
  end

  describe 'title and clock' do
    it 'needs no title and stores a blank one as nil' do
      expect(create(:conversation, creator: creator, title: nil).title).to be_nil
      expect(create(:conversation, creator: creator, title: "  \n ").reload.title).to be_nil
      expect(create(:conversation, creator: creator, title: '  Angebot  ').reload.title).to eq('Angebot')
    end

    it 'takes a title of 255 characters and refuses one more' do
      expect(build(:conversation, creator: creator, title: 'a' * 255)).to be_valid

      record = build(:conversation, creator: creator, title: 'a' * 256)
      expect(record).not_to be_valid
      expect(record.errors.added?(:title, :too_long, count: 255)).to be(true)
    end

    it 'holds the length in the database too, past the validations' do
      conversation

      expect { described_class.where(id: conversation.id).update_all(title: 'a' * 256) }
        .to raise_error(ActiveRecord::ValueTooLong)
    end

    it 'sets last_post_at on create when none is given, and keeps a given one' do
      given = 3.days.ago.change(usec: 0)

      expect(create(:conversation, creator: creator).last_post_at).to be_within(5.seconds).of(Time.current)
      expect(create(:conversation, creator: creator, last_post_at: given).reload.last_post_at).to eq(given)
    end

    it 'refuses a row without last_post_at at the database' do
      conversation

      expect { described_class.where(id: conversation.id).update_all(last_post_at: nil) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end

    it 'refuses a row without a creator at the database' do
      conversation

      expect { described_class.where(id: conversation.id).update_all(creator_id: nil) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe 'deleting a conversation' do
    let(:participant) { member_of(organisation) }
    let!(:row) { take_part(participant) }
    let!(:message) { create(:conversation_post, conversation: conversation, user: participant) }

    def rich_texts
      ActionText::RichText.where(record_type: 'ConversationPost', record_id: message.id)
    end

    it 'takes participants, posts and the rich text of the posts with it through the model' do
      expect(rich_texts.count).to eq(1)

      conversation.destroy!

      expect(ConversationParticipant.where(id: row.id)).to be_empty
      expect(ConversationPost.where(id: message.id)).to be_empty
      expect(rich_texts.count).to eq(0)
    end

    # The reason for dependent: :destroy. The cascade of the database removes the rows
    # and knows nothing of the rich text record.
    it 'takes participants and posts with it at the database, and leaves the rich text behind there' do
      described_class.where(id: conversation.id).delete_all

      expect(ConversationParticipant.where(id: row.id)).to be_empty
      expect(ConversationPost.where(id: message.id)).to be_empty
      expect(rich_texts.count).to eq(1)
    end
  end

  describe 'what the model is not' do
    it 'has no activity trail, no embeddings and no association named posts' do
      expect(described_class.include?(Trackable)).to be(false)
      expect(described_class.reflect_on_association(:fragments)).to be_nil
      expect(described_class.reflect_on_association(:posts)).to be_nil
      expect(described_class.reflect_on_all_associations(:has_many).map(&:name))
        .to contain_exactly(:conversation_participants, :conversation_posts)
    end

    it 'has no column that archives a conversation for everybody' do
      expect(described_class.column_names).not_to include('archived_at')
    end
  end

  describe 'the factory' do
    it 'builds a valid record, plain and with every trait' do
      expect(build(:conversation)).to be_valid
      expect(create(:conversation, :untitled).title).to be_nil
      expect(create(:conversation, :labelled).project.organisation_id).to eq(organisation.id)
    end
  end
end
