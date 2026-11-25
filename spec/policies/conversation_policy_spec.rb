# frozen_string_literal: true

require 'rails_helper'

# What: ConversationPolicy asks one thing, Conversation.visible_to: its scope is that
#   scope, and every question about a conversation first asks whether the person reads it.
# Why: a conversation is correspondence between the people in it. No admin role and no
#   right on the labelled project answers yes, and a policy with a shortcut of its own
#   would be a second rule beside the one.
# Each refusal stands next to a yes of the same person, and a person is loaded fresh after
#   their membership changed (User#active_member_of_organisation? remembers a yes).
RSpec.describe ConversationPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:creator) { member_of(organisation) }
  let(:conversation) { create(:conversation, creator: creator) }
  let(:second_conversation) { create(:conversation, creator: creator, title: 'Rückfrage zur Rechnung') }
  let(:admin_role) { role_in(organisation, title: Role::ACCOUNT_ADMIN_TITLE) }

  # The questions that mean "this person takes part and reads".
  let(:participant_questions) do
    %i[show? create_post? update? archive? mute? read? add_participant? remove_participant?]
  end

  before do
    ActsAsTenant.current_tenant = organisation
    take_part(creator)
  end

  after { ActsAsTenant.current_tenant = nil }

  def role_in(org, **attributes)
    ActsAsTenant.with_tenant(org) { create(:role, organisation: org, **attributes) }
  end

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

  # The participant questions the policy answers with yes, for one person and one conversation.
  def yes_to(user, record = conversation)
    policy = described_class.new(user, record)
    participant_questions.select { |question| policy.public_send(question) }
  end

  def listed_for(user)
    Pundit.policy_scope!(user, Conversation).to_a
  end

  describe 'the scope' do
    it 'is the scope Pundit finds for Conversation, and it is the read rule' do
      participant = member_of(organisation)
      take_part(participant)
      second_conversation

      expect(Pundit::PolicyFinder.new(Conversation).scope).to eq(described_class::Scope)
      expect(listed_for(participant)).to contain_exactly(conversation)
      expect(listed_for(participant)).to match_array(Conversation.visible_to(participant))
    end

    it 'lists nothing of a conversation the person does not take part in, whatever their role' do
      member = member_of(organisation)
      admin = member_of(organisation, role: admin_role)
      take_part(member, second_conversation)
      take_part(admin, second_conversation)

      expect(admin.account_admin_in?(organisation)).to be(true)
      expect(listed_for(member)).to contain_exactly(second_conversation)
      expect(listed_for(admin)).to contain_exactly(second_conversation)
    end

    it 'lists nothing for a member with full access to the labelled project who does not take part' do
      project = create(:project, organisation: organisation)
      reader = member_of(organisation)
      create(:project_permission, user: reader, project: project, tickets_access: 'read_write',
                                  notes_access: 'read_write', chats_access: 'read_write',
                                  documents_access: 'read_write', members_access: 'read_write',
                                  documentation_access: 'read_write', meetings_access: 'read_write')
      labelled = create(:conversation, creator: creator, project: project, title: 'Zum Beispielprojekt')
      take_part(reader, second_conversation)

      expect(ProjectPolicy.new(reader, project).show?).to be(true)
      expect(listed_for(reader)).to contain_exactly(second_conversation)
      expect(yes_to(reader, labelled)).to be_empty
    end

    it 'lists nothing once the membership is deactivated or gone, or the participant row is gone' do
      deactivated = member_of(organisation)
      removed = member_of(organisation)
      left = member_of(organisation)
      take_part(deactivated)
      take_part(removed)
      row = take_part(left)
      expect(listed_for(deactivated)).to contain_exactly(conversation)
      expect(listed_for(removed)).to contain_exactly(conversation)
      expect(listed_for(left)).to contain_exactly(conversation)

      membership_of(deactivated).update!(active: false)
      membership_of(removed).destroy!
      row.destroy!

      expect(listed_for(fresh(deactivated))).to be_empty
      expect(listed_for(fresh(removed))).to be_empty
      expect(listed_for(fresh(left))).to be_empty
    end
  end

  describe 'the questions about a conversation' do
    it 'says yes to a participant who is an active member' do
      participant = member_of(organisation)
      take_part(participant)

      expect(yes_to(participant)).to eq(participant_questions)
    end

    it 'says no to an active member who does not take part in it' do
      member = member_of(organisation)
      take_part(member, second_conversation)

      expect(yes_to(member, second_conversation)).to eq(participant_questions)
      expect(yes_to(member)).to be_empty
    end

    it 'says no to an account admin who does not take part, to every question' do
      admin = member_of(organisation, role: admin_role)
      take_part(admin, second_conversation)
      policy = described_class.new(admin, conversation)

      expect(admin.account_admin_in?(organisation)).to be(true)
      expect(yes_to(admin, second_conversation)).to eq(participant_questions)
      expect(yes_to(admin)).to be_empty
      expect(policy.destroy?).to be(false)
      expect(policy.edit?).to be(false)
    end

    it 'says no to a participant whose membership is deactivated, and yes again once it is active' do
      participant = member_of(organisation)
      take_part(participant)
      expect(yes_to(participant)).to eq(participant_questions)

      membership_of(participant).update!(active: false)
      expect(yes_to(fresh(participant))).to be_empty

      membership_of(participant).update!(active: true)
      expect(yes_to(fresh(participant))).to eq(participant_questions)
    end

    it 'says no to a participant whose membership is gone' do
      participant = member_of(organisation)
      take_part(participant)
      expect(yes_to(participant)).to eq(participant_questions)

      membership_of(participant).destroy!

      expect(yes_to(fresh(participant))).to be_empty
    end

    it 'says no to somebody whose participant row is gone' do
      participant = member_of(organisation)
      row = take_part(participant)
      expect(yes_to(participant)).to eq(participant_questions)

      row.destroy!

      expect(yes_to(fresh(participant))).to be_empty
    end

    it 'says no about a conversation of another organisation' do
      visitor = member_of(organisation)
      create(:membership, user: visitor, organisation: other_organisation, role: role_in(other_organisation))
      take_part(visitor)
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        there = create(:conversation, creator: member_of(other_organisation))
        take_part(visitor, there)
        there
      end

      expect(ActsAsTenant.with_tenant(other_organisation) { yes_to(fresh(visitor), foreign) }).to eq(participant_questions)
      expect(yes_to(fresh(visitor))).to eq(participant_questions)
      expect(yes_to(fresh(visitor), foreign)).to be_empty
    end
  end

  describe 'create?' do
    it 'says yes to an active member of the organisation' do
      expect(described_class.new(member_of(organisation), Conversation).create?).to be(true)
      expect(described_class.new(member_of(organisation), Conversation).new?).to be(true)
    end

    it 'says no to a deactivated member, also after the membership was active' do
      member = member_of(organisation)
      expect(described_class.new(member, Conversation).create?).to be(true)

      membership_of(member).update!(active: false)

      expect(described_class.new(fresh(member), Conversation).create?).to be(false)
      expect(described_class.new(member_of(organisation, active: false), Conversation).create?).to be(false)
    end

    # User#active_member_of_organisation? remembers a yes on the object. The policy asks
    # the membership itself, so the answer does not outlive a deactivation.
    it 'says no after a deactivation to the very user object that got a yes before' do
      member = member_of(organisation)
      expect(described_class.new(member, Conversation).create?).to be(true)
      expect(member.active_member_of_organisation?(organisation)).to be(true)

      membership_of(member).update!(active: false)

      expect(described_class.new(member, Conversation).create?).to be(false)
    end

    it 'says no where no organisation is set' do
      member = member_of(organisation)
      expect(described_class.new(member, Conversation).create?).to be(true)

      ActsAsTenant.current_tenant = nil

      expect(described_class.new(fresh(member), Conversation).create?).to be(false)
    end

    it 'says no to somebody without a membership here' do
      visitor = member_of(other_organisation)

      expect(visitor.active_member_of_organisation?(other_organisation)).to be(true)
      expect(described_class.new(visitor, Conversation).create?).to be(false)
      expect(described_class.new(create(:user), Conversation).create?).to be(false)
    end
  end

  describe 'destroy?' do
    let(:participant) { member_of(organisation) }

    before { take_part(participant) }

    it 'says yes to the creator, and no to another participant while the creator is an active member' do
      expect(described_class.new(creator, conversation).destroy?).to be(true)
      expect(yes_to(participant)).to eq(participant_questions)
      expect(described_class.new(participant, conversation).destroy?).to be(false)
    end

    it 'says yes to another participant once the membership of the creator is deactivated' do
      expect(described_class.new(participant, conversation).destroy?).to be(false)

      membership_of(creator).update!(active: false)

      expect(described_class.new(fresh(participant), conversation).destroy?).to be(true)
    end

    it 'says yes to another participant once the membership of the creator is gone' do
      expect(described_class.new(participant, conversation).destroy?).to be(false)

      membership_of(creator).destroy!

      expect(described_class.new(fresh(participant), conversation).destroy?).to be(true)
    end

    # One policy object answers several questions of a page. What it learnt about one
    # membership must not stand in for another: the asker's yes is not the creator's.
    it 'asks about the creator afresh on a policy object that already answered create?' do
      policy = described_class.new(participant, conversation)
      expect(policy.create?).to be(true)

      membership_of(creator).update!(active: false)

      expect(policy.destroy?).to be(true)
    end

    it 'says no to a creator whose own membership is deactivated' do
      expect(described_class.new(creator, conversation).destroy?).to be(true)

      membership_of(creator).update!(active: false)

      expect(described_class.new(fresh(creator), conversation).destroy?).to be(false)
    end

    it 'says no to somebody who does not take part, also once the creator is no member any more' do
      bystander = member_of(organisation)
      admin = member_of(organisation, role: admin_role)
      membership_of(creator).update!(active: false)

      expect(described_class.new(fresh(participant), conversation).destroy?).to be(true)
      expect(described_class.new(bystander, conversation).destroy?).to be(false)
      expect(described_class.new(admin, conversation).destroy?).to be(false)
    end

    # The creator of ANOTHER organisation's membership does not count: the question is
    # asked in the organisation of the conversation.
    it 'asks for the membership of the creator in the organisation of the conversation' do
      create(:membership, user: creator, organisation: other_organisation, role: role_in(other_organisation))
      membership_of(creator).update!(active: false)

      expect(fresh(creator).active_member_of_organisation?(other_organisation)).to be(true)
      expect(described_class.new(fresh(participant), conversation).destroy?).to be(true)
    end
  end

  describe 'what the policy does not answer yet' do
    it 'defines no question of its own for a list, for inviting a guest or for a successor' do
      defined = described_class.instance_methods(false) + described_class.private_instance_methods(false)

      expect(defined).to include(:show?, :create?, :destroy?)
      expect(defined).not_to include(:index?, :invite_guest?, :decide_successor?)
      expect(described_class.new(creator, conversation).index?).to be(false)
    end
  end
end
