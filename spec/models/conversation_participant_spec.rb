# frozen_string_literal: true

require 'rails_helper'

# What: a participant row. It names an account that is an active member of the
#   conversation's organisation when the row is written, it stands in that organisation
#   and nowhere else, and there is one row per person and conversation.
# Why: the list of these rows is the right to read a conversation
#   (Conversation.visible_to). A row that could name a conversation of another
#   organisation, or a person who is no member, would hand out that right.
RSpec.describe ConversationParticipant, :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:creator) { member_of(organisation) }
  let(:conversation) { create(:conversation, creator: creator) }
  let(:foreign_conversation) do
    ActsAsTenant.with_tenant(other_organisation) { create(:conversation, creator: member_of(other_organisation)) }
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_in(org)
    ActsAsTenant.with_tenant(org) { create(:role, organisation: org) }
  end

  def member_of(org, active: true)
    user = create(:user)
    create(:membership, user: user, organisation: org, role: role_in(org), active: active)
    User.find(user.id)
  end

  def row_for(user, **attributes)
    described_class.new(conversation: conversation, user: user, **attributes)
  end

  describe 'the tenant' do
    it 'raises on a read without a tenant' do
      create(:conversation_participant, conversation: conversation)
      ActsAsTenant.current_tenant = nil

      expect { described_class.count }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
    end

    it 'does not find a row of another organisation' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:conversation_participant, conversation: foreign_conversation)
      end

      expect(ActsAsTenant.with_tenant(other_organisation) { described_class.exists?(foreign.id) }).to be(true)
      expect(described_class.where(id: foreign.id)).to be_empty
    end
  end

  describe 'the conversation, inside the same organisation' do
    let(:member) { member_of(organisation) }

    it 'takes a conversation of its own organisation' do
      row = row_for(member)

      expect(row).to be_valid
      expect(row.tap(&:save!).organisation_id).to eq(organisation.id)
    end

    it 'checks an unsaved conversation before autosave, without a tenant' do
      person = member

      ActsAsTenant.without_tenant do
        own = Conversation.new(organisation: organisation, creator: person)
        foreign = Conversation.new(organisation: other_organisation, creator: person)
        fine = described_class.new(organisation: organisation, user: person, conversation: own)
        row = described_class.new(organisation: organisation, user: person, conversation: foreign)

        fine.save!
        expect(fine.reload.conversation_id).to eq(own.id)
        expect(own.reload.organisation_id).to eq(organisation.id)
        expect(row.conversation_id).to be_nil
        expect(row).not_to be_valid
        expect(row.errors.added?(:conversation, :invalid)).to be(true)
        expect { row.save! }.to raise_error(ActiveRecord::RecordInvalid)
        expect(foreign).to be_new_record
      end
    end

    it 'checks a changed conversation id even when an unsaved conversation was assigned before it' do
      own_id = conversation.id
      foreign_id = foreign_conversation.id
      person = member

      ActsAsTenant.without_tenant do
        draft = Conversation.new(organisation: organisation, creator: person)
        row = described_class.new(organisation: organisation, user: person, conversation: draft)
        row.conversation_id = foreign_id

        expect(row).not_to be_valid
        expect(row.errors.added?(:conversation, :invalid)).to be(true)
        expect { row.save! }.to raise_error(ActiveRecord::RecordInvalid)

        row.update!(conversation_id: own_id)
        expect(row.reload.conversation_id).to eq(own_id)
        expect(draft).to be_new_record
      end
    end

    # Twice over: the tenant check of a reference declared before acts_as_tenant, and
    # the model's own check, which also holds where no tenant is set.
    it 'refuses a conversation of another organisation under its own tenant' do
      row = described_class.new(conversation_id: foreign_conversation.id, user: member)

      expect(row).not_to be_valid
      expect(row.errors[:conversation_id]).to include('association is invalid [ActsAsTenant]')
      expect(row.errors.added?(:conversation, :invalid)).to be(true)
    end

    it 'refuses it as well when no tenant is set' do
      own_id = conversation.id
      foreign_id = foreign_conversation.id

      ActsAsTenant.without_tenant do
        fine = described_class.new(organisation: organisation, conversation_id: own_id, user: member)
        row = described_class.new(organisation: organisation, conversation_id: foreign_id, user: member)

        expect(fine).to be_valid
        expect(row).not_to be_valid
        expect(row.errors.added?(:conversation, :invalid)).to be(true)
      end
    end

    it 'refuses it as well on a row that exists' do
      row = row_for(member).tap(&:save!)

      expect(row.update(conversation_id: foreign_conversation.id)).to be(false)
      expect(row.errors.added?(:conversation, :invalid)).to be(true)
      expect(row.reload.conversation_id).to eq(conversation.id)
    end

    it 'refuses it as well under the other tenant, which stamps the row as its own' do
      own_id = conversation.id
      visitor = member_of(other_organisation)

      ActsAsTenant.with_tenant(other_organisation) do
        row = described_class.new(conversation_id: own_id, user: visitor)

        expect(row).not_to be_valid
        expect(row.organisation_id).to eq(other_organisation.id)
        expect(row.errors.added?(:conversation, :invalid)).to be(true)
      end
    end
  end

  describe 'the participant, an active member when the row is written' do
    it 'takes an active member of the organisation' do
      expect(row_for(member_of(organisation))).to be_valid
    end

    it 'refuses a deactivated member' do
      row = row_for(member_of(organisation, active: false))

      expect(row).not_to be_valid
      expect(row.errors.added?(:user, :not_an_active_member)).to be(true)
    end

    it 'refuses somebody without a membership' do
      row = row_for(create(:user))

      expect(row).not_to be_valid
      expect(row.errors.added?(:user, :not_an_active_member)).to be(true)
    end

    it 'refuses somebody who is an active member of another organisation only' do
      visitor = member_of(other_organisation)
      row = row_for(visitor)

      expect(visitor.active_member_of_organisation?(other_organisation)).to be(true)
      expect(row).not_to be_valid
      expect(row.errors.added?(:user, :not_an_active_member)).to be(true)
    end

    it 'keeps a row savable when its member is deactivated later' do
      member = member_of(organisation)
      row = row_for(member).tap(&:save!)

      Membership.find_by!(user_id: member.id, organisation_id: organisation.id).update!(active: false)
      row = described_class.find(row.id)

      expect(row.update(archived_at: Time.current)).to be(true)
      expect(row.reload.archived_at).to be_present
    end

    it 'asks again when the row is given to another person' do
      row = row_for(member_of(organisation)).tap(&:save!)

      row.user = member_of(organisation, active: false)

      expect(row).not_to be_valid
      expect(row.errors.added?(:user, :not_an_active_member)).to be(true)
    end

    it 'says so in German and in English' do
      row = row_for(create(:user))

      row.validate
      messages = %i[de en].map do |locale|
        I18n.with_locale(locale) { row.errors.generate_message(:user, :not_an_active_member) }
      end
      expect(row.errors.added?(:user, :not_an_active_member)).to be(true)

      expect(messages).to eq(['muss ein aktives Mitglied dieser Organisation sein',
                              'must be an active member of this organisation'])
    end
  end

  describe 'one row per person and conversation' do
    let(:member) { member_of(organisation) }

    before { row_for(member).save! }

    it 'refuses a second row in the model' do
      second = row_for(member)

      expect(second).not_to be_valid
      expect(second.errors.added?(:user_id, :taken, value: member.id)).to be(true)
    end

    it 'refuses a second row at the database, past the validations' do
      expect { row_for(member).save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'takes the same person in another conversation' do
      elsewhere = create(:conversation, creator: creator)

      expect(described_class.new(conversation: elsewhere, user: member)).to be_valid
    end
  end

  describe 'a row names an account' do
    it 'refuses a row without a user in the model' do
      row = row_for(nil)

      expect(row).not_to be_valid
      expect(row.errors.added?(:user, :blank)).to be(true)
    end

    it 'refuses a row without a user at the database, past the validations' do
      row = row_for(member_of(organisation)).tap(&:save!)

      expect { described_class.where(id: row.id).update_all(user_id: nil) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe 'what the model is not' do
    it 'has no flag that ends a participation, no activity trail and no embeddings' do
      expect(described_class.column_names).not_to include('ended_at', 'left_at', 'removed_at', 'deleted_at', 'active')
      expect(described_class.include?(Trackable)).to be(false)
      expect(described_class.reflect_on_association(:fragments)).to be_nil
    end
  end

  describe 'the factory' do
    it 'builds a valid record, built or created, plain and with its trait' do
      expect(build(:conversation_participant)).to be_valid
      expect(create(:conversation_participant, conversation: conversation)).to be_persisted
      expect(create(:conversation_participant, :added, conversation: conversation).added_by).to eq(creator)
    end
  end
end
