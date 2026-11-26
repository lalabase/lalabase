# frozen_string_literal: true

require 'rails_helper'

# What: one entry of a conversation. A message has a text and no system_event; a system
#   entry has a system_event and no text. Kind and origin come from two lists. The entry
#   stands in the organisation of its conversation, and so does an invitation it names.
# Why: a system entry holds a key and ids, never a name or a sentence, so nothing
#   personal stays in it. And a post that could name a conversation of another
#   organisation would be written into a place its author cannot see.
# The rules hold twice where it matters: in the model for a message a person can read,
#   and in the database for a write that goes past the model.
RSpec.describe ConversationPost, :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:author) { member_of(organisation) }
  let(:conversation) { create(:conversation, creator: author) }
  let(:foreign_conversation) do
    ActsAsTenant.with_tenant(other_organisation) { create(:conversation, creator: member_of(other_organisation)) }
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_in(org)
    ActsAsTenant.with_tenant(org) { create(:role, organisation: org) }
  end

  def member_of(org)
    user = create(:user)
    create(:membership, user: user, organisation: org, role: role_in(org), active: true)
    User.find(user.id)
  end

  def message(**attributes)
    described_class.new(conversation: conversation, user: author, content: 'Guten Morgen', **attributes)
  end

  def system_entry(**attributes)
    described_class.new(conversation: conversation, user: author, kind: 'system',
                        system_event: 'participant_added', **attributes)
  end

  def rich_texts_of(post)
    ActionText::RichText.where(record_type: 'ConversationPost', record_id: post.id)
  end

  describe 'the tenant' do
    it 'raises on a read without a tenant' do
      message.save!
      ActsAsTenant.current_tenant = nil

      expect { described_class.count }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
      expect { described_class.visible_to(author).to_a }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
    end

    it 'does not find a post of another organisation' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:conversation_post, conversation: foreign_conversation)
      end

      expect(ActsAsTenant.with_tenant(other_organisation) { described_class.exists?(foreign.id) }).to be(true)
      expect(described_class.where(id: foreign.id)).to be_empty
    end
  end

  describe 'the conversation, inside the same organisation' do
    it 'takes a conversation of its own organisation' do
      post = message

      expect(post).to be_valid
      expect(post.tap(&:save!).organisation_id).to eq(organisation.id)
    end

    it 'checks an unsaved conversation before autosave, without a tenant' do
      writer = author

      ActsAsTenant.without_tenant do
        own = Conversation.new(organisation: organisation, creator: writer)
        foreign = Conversation.new(organisation: other_organisation, creator: writer)
        attributes = { organisation: organisation, user: writer, content: 'Guten Morgen' }
        fine = described_class.new(**attributes, conversation: own)
        post = described_class.new(**attributes, conversation: foreign)

        fine.save!
        expect(fine.reload.conversation_id).to eq(own.id)
        expect(own.reload.organisation_id).to eq(organisation.id)
        expect(post.conversation_id).to be_nil
        expect(post).not_to be_valid
        expect(post.errors.added?(:conversation, :invalid)).to be(true)
        expect { post.save! }.to raise_error(ActiveRecord::RecordInvalid)
        expect(foreign).to be_new_record
      end
    end

    it 'checks a changed conversation id even when an unsaved conversation was assigned before it' do
      own_id = conversation.id
      foreign_id = foreign_conversation.id
      writer = author

      ActsAsTenant.without_tenant do
        draft = Conversation.new(organisation: organisation, creator: writer)
        post = described_class.new(organisation: organisation, user: writer, conversation: draft, content: 'Guten Morgen')
        post.conversation_id = foreign_id

        expect(post).not_to be_valid
        expect(post.errors.added?(:conversation, :invalid)).to be(true)
        expect { post.save! }.to raise_error(ActiveRecord::RecordInvalid)

        post.update!(conversation_id: own_id)
        expect(post.reload.conversation_id).to eq(own_id)
        expect(draft).to be_new_record
      end
    end

    it 'refuses a conversation of another organisation under its own tenant' do
      post = described_class.new(conversation_id: foreign_conversation.id, user: author, content: 'Guten Morgen')

      expect(post).not_to be_valid
      expect(post.errors[:conversation_id]).to include('association is invalid [ActsAsTenant]')
      expect(post.errors.added?(:conversation, :invalid)).to be(true)
    end

    it 'refuses it as well when no tenant is set' do
      own_id = conversation.id
      foreign_id = foreign_conversation.id

      ActsAsTenant.without_tenant do
        fine = described_class.new(organisation: organisation, conversation_id: own_id, user: author, content: 'Guten Morgen')
        post = described_class.new(organisation: organisation, conversation_id: foreign_id, user: author,
                                   content: 'Guten Morgen')

        expect(fine).to be_valid
        expect(post).not_to be_valid
        expect(post.errors.added?(:conversation, :invalid)).to be(true)
      end
    end

    it 'refuses it as well under the other tenant, which stamps the row as its own' do
      own_id = conversation.id

      ActsAsTenant.with_tenant(other_organisation) do
        post = described_class.new(conversation_id: own_id, user: author, content: 'Guten Morgen')

        expect(post).not_to be_valid
        expect(post.organisation_id).to eq(other_organisation.id)
        expect(post.errors.added?(:conversation, :invalid)).to be(true)
      end
    end
  end

  describe 'the invitation of a system entry, inside the same organisation' do
    let(:invitation) { create(:invitation, organisation: organisation, email: 'gast@example.com', inviter: author) }
    let(:foreign_invitation) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:invitation, organisation: other_organisation, email: 'fremd@example.com',
                            inviter: member_of(other_organisation))
      end
    end

    it 'takes an invitation of its own organisation, and none' do
      expect(system_entry(invitation: invitation)).to be_valid
      expect(system_entry).to be_valid
    end

    it 'checks an unsaved invitation before autosave, without a tenant' do
      writer = author
      own_conversation = conversation

      ActsAsTenant.without_tenant do
        own = Invitation.new(organisation: organisation, inviter: writer, email: 'own@example.com')
        foreign = Invitation.new(organisation: other_organisation, inviter: writer, email: 'foreign@example.com')
        attributes = { organisation: organisation, conversation: own_conversation, user: writer,
                       kind: 'system', system_event: 'guest_invited' }
        fine = described_class.new(**attributes, invitation: own)
        entry = described_class.new(**attributes, invitation: foreign)

        fine.save!
        expect(fine.reload.invitation_id).to eq(own.id)
        expect(own.reload.organisation_id).to eq(organisation.id)
        expect(entry.invitation_id).to be_nil
        expect(entry).not_to be_valid
        expect(entry.errors.added?(:invitation, :invalid)).to be(true)
        expect { entry.save! }.to raise_error(ActiveRecord::RecordInvalid)
        expect(foreign).to be_new_record
      end
    end

    it 'checks a changed invitation id even when an unsaved invitation was assigned before it' do
      own_id = invitation.id
      foreign_id = foreign_invitation.id
      writer = author
      entry = system_entry

      ActsAsTenant.without_tenant do
        draft = Invitation.new(organisation: organisation, inviter: writer, email: 'unused@example.com')
        entry.invitation = draft
        entry.invitation_id = foreign_id

        expect(entry).not_to be_valid
        expect(entry.errors.added?(:invitation, :invalid)).to be(true)
        expect { entry.save! }.to raise_error(ActiveRecord::RecordInvalid)

        entry.update!(invitation_id: own_id)
        expect(entry.reload.invitation_id).to eq(own_id)
        expect(draft).to be_new_record
      end
    end

    it 'refuses an invitation of another organisation under its own tenant' do
      entry = system_entry(invitation_id: foreign_invitation.id)

      expect(entry).not_to be_valid
      expect(entry.errors[:invitation_id]).to include('association is invalid [ActsAsTenant]')
      expect(entry.errors.added?(:invitation, :invalid)).to be(true)
    end

    it 'refuses it as well when no tenant is set' do
      own_id = invitation.id
      foreign_id = foreign_invitation.id
      conversation_id = conversation.id

      ActsAsTenant.without_tenant do
        attributes = { organisation: organisation, conversation_id: conversation_id, user: author, kind: 'system',
                       system_event: 'guest_invited' }
        fine = described_class.new(**attributes, invitation_id: own_id)
        entry = described_class.new(**attributes, invitation_id: foreign_id)

        expect(fine).to be_valid
        expect(entry).not_to be_valid
        expect(entry.errors.added?(:invitation, :invalid)).to be(true)
      end
    end

    it 'refuses it as well under the other tenant, which stamps the row as its own' do
      own_id = invitation.id

      ActsAsTenant.with_tenant(other_organisation) do
        entry = described_class.new(conversation: foreign_conversation, user: author, kind: 'system',
                                    system_event: 'guest_invited', invitation_id: own_id)

        expect(entry).not_to be_valid
        expect(entry.organisation_id).to eq(other_organisation.id)
        expect(entry.errors.added?(:invitation, :invalid)).to be(true)
      end
    end

    it 'refuses it as well on an entry that exists, for the invitation and for the conversation' do
      entry = system_entry.tap(&:save!)

      expect(entry.update(invitation_id: foreign_invitation.id)).to be(false)
      expect(entry.errors.added?(:invitation, :invalid)).to be(true)
      expect(described_class.find(entry.id).update(conversation_id: foreign_conversation.id)).to be(false)
      expect(entry.reload).to have_attributes(invitation_id: nil, conversation_id: conversation.id)
      expect(entry.update(invitation: invitation)).to be(true)
    end

    it 'empties the reference when the invitation row is deleted' do
      entry = system_entry(invitation: invitation).tap(&:save!)

      Invitation.where(id: invitation.id).delete_all

      expect(entry.reload.invitation_id).to be_nil
    end
  end

  describe 'a message' do
    it 'is the default kind, comes from the web by default and needs a text' do
      post = described_class.new(conversation: conversation, user: author)

      expect(post.kind).to eq('message')
      expect(post.origin).to eq('web')
      expect(post).not_to be_valid
      expect(post.errors.added?(:content, :blank)).to be(true)
      expect(message).to be_valid
    end

    it 'has no system_event' do
      post = message(system_event: 'participant_added')

      expect(post).not_to be_valid
      expect(post.errors.added?(:system_event, :not_for_a_message)).to be(true)
    end

    ['', ' '].each do |event|
      it "refuses a non-null blank system_event #{event.inspect} before reaching the database" do
        post = message(system_event: event)

        expect(post).not_to be_valid
        expect(post.errors.added?(:system_event, :not_for_a_message)).to be(true)
        expect { post.save! }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    it 'stores its text as rich text and mirrors it' do
      post = message(content: '<p>Guten <strong>Morgen</strong></p>').tap(&:save!)

      expect(rich_texts_of(post).count).to eq(1)
      expect(post.reload.plain_text_version).to eq('Guten Morgen')
      expect(post.plain_text_word_count).to eq(2)
    end

    it 'needs an author, in the model and at the database' do
      post = message(user: nil)
      saved = message.tap(&:save!)

      expect(post).not_to be_valid
      expect(post.errors.added?(:user, :blank)).to be(true)
      expect { described_class.where(id: saved.id).update_all(user_id: nil) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe 'a system entry' do
    it 'has a system_event' do
      entry = system_entry(system_event: nil)

      expect(system_entry).to be_valid
      expect(entry).not_to be_valid
      expect(entry.errors.added?(:system_event, :blank)).to be(true)
    end

    it 'has no text' do
      entry = system_entry(content: 'Eine Person wurde hinzugefügt')

      expect(entry).not_to be_valid
      expect(entry.errors.added?(:content, :not_for_a_system_entry)).to be(true)
    end

    # Not even an empty one: asking a rich text for its content builds the record.
    it 'writes no rich text record and no mirror' do
      entry = system_entry.tap(&:save!)

      expect(rich_texts_of(entry)).to be_empty
      expect(entry.reload.plain_text_version).to be_nil
      expect(entry.plain_text_word_count).to be_nil

      entry.update!(subject_user: author)

      expect(rich_texts_of(entry)).to be_empty
    end

    it 'clears both mirrors when a saved message becomes a system entry' do
      post = message(content: 'Private message text').tap(&:save!)
      expect(post.reload.plain_text_version).to eq('Private message text')
      expect(post.plain_text_word_count).to eq(3)

      post.update!(kind: 'system', system_event: 'participant_added', content: nil)

      expect(post.reload).to be_system
      expect(post.plain_text_version).to be_nil
      expect(post.plain_text_word_count).to be_nil
    end

    it 'holds a key, never a sentence' do
      valid = ['participant_added', 'guest_invited_2', 'a' * 64]
      invalid = ['Participant added', 'participant-added', 'Hinzugefügt', 'a' * 65, 'x y', "participant_added\n",
                 "participant_added\nmore"]

      # One validation per key is the point here, not an N+1 to report.
      Prosopite.pause do
        expect(valid.map { |key| system_entry(system_event: key).valid? }).to all(be(true))
        expect(invalid.map { |key| system_entry(system_event: key).valid? }).to all(be(false))
      end
      expect(system_entry(system_event: 'x y').tap(&:validate).errors.added?(:system_event, :invalid, value: 'x y')).to be(true)
    end

    it 'names the people it is about by id and keeps no name' do
      subject_user = member_of(organisation)
      entry = system_entry(subject_user: subject_user, second_user: author).tap(&:save!)

      expect(entry.reload.subject_user).to eq(subject_user)
      expect(entry.second_user).to eq(author)
      expect(described_class.column_names.grep(/name|label|text\z|sentence/)).to be_empty
    end
  end

  describe 'kind and origin' do
    it 'takes only a known kind and a known origin in the model' do
      expect(described_class::KINDS).to eq(%w[message system])
      expect(described_class::ORIGINS).to eq(%w[web token assistant])
      Prosopite.pause do
        expect(described_class::ORIGINS.map { |origin| message(origin: origin).valid? }).to all(be(true))
        expect(message(kind: 'note').tap(&:validate).errors.added?(:kind, :inclusion, value: 'note')).to be(true)
        expect(message(origin: 'mail').tap(&:validate).errors.added?(:origin, :inclusion, value: 'mail')).to be(true)
      end
    end

    it 'says its refusals in German and in English' do
      no_event = message(system_event: 'participant_added')
      with_text = system_entry(content: 'Text')

      no_event.validate
      with_text.validate
      texts = %i[de en].map do |locale|
        I18n.with_locale(locale) do
          [no_event.errors.generate_message(:system_event, :not_for_a_message),
           with_text.errors.generate_message(:content, :not_for_a_system_entry)]
        end
      end
      expect(no_event.errors.added?(:system_event, :not_for_a_message)).to be(true)
      expect(with_text.errors.added?(:content, :not_for_a_system_entry)).to be(true)

      expect(texts).to eq([['darf bei einer Nachricht nicht stehen', 'darf bei einem Systemeintrag nicht stehen'],
                           ['must be empty on a message', 'must be empty on a system entry']])
    end
  end

  describe 'the same rules at the database, past the validations' do
    let!(:saved_message) { message.tap(&:save!) }
    let!(:saved_entry) { system_entry.tap(&:save!) }

    it 'refuses a kind outside the list' do
      expect { described_class.where(id: saved_message.id).update_all(kind: 'note') }
        .to raise_error(ActiveRecord::CheckViolation, /conversation_posts_kind_known/)
    end

    it 'refuses an origin outside the list' do
      expect { described_class.where(id: saved_message.id).update_all(origin: 'mail') }
        .to raise_error(ActiveRecord::CheckViolation, /conversation_posts_origin_known/)
    end

    it 'refuses a message with a system_event' do
      expect { described_class.where(id: saved_message.id).update_all(system_event: 'participant_added') }
        .to raise_error(ActiveRecord::CheckViolation, /conversation_posts_system_event_by_kind/)
    end

    it 'refuses a system entry without a system_event' do
      expect { described_class.where(id: saved_entry.id).update_all(system_event: nil) }
        .to raise_error(ActiveRecord::CheckViolation, /conversation_posts_system_event_by_kind/)
    end

    it 'takes every origin of the list' do
      expect(described_class.where(id: saved_message.id).update_all(origin: 'token')).to eq(1)
      expect(described_class.where(id: saved_message.id).update_all(origin: 'assistant')).to eq(1)
    end
  end

  describe 'what the model carries and what it does not' do
    it 'guards the images of its rich text and mirrors its text' do
      expect(described_class.include?(RichTextEmbedGuard)).to be(true)
      expect(described_class.include?(RichTextBody)).to be(true)
    end

    it 'has no activity trail, no embeddings and no file attachments' do
      expect(described_class.include?(Trackable)).to be(false)
      expect(described_class.reflect_on_association(:fragments)).to be_nil
      expect(described_class.reflect_on_all_associations.map(&:name).grep(/attachment/)).to be_empty
    end
  end

  describe 'the factory' do
    it 'builds a valid record, plain and with its trait' do
      expect(build(:conversation_post)).to be_valid
      expect(create(:conversation_post, conversation: conversation).content.to_plain_text).to be_present
      entry = create(:conversation_post, :system, conversation: conversation)

      expect(entry).to be_system
      expect(rich_texts_of(entry)).to be_empty
    end
  end
end
