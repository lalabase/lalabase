# frozen_string_literal: true

# == Schema Information
#
# Table name: chats
#
#  id                    :uuid             not null, primary key
#  language              :string
#  language_locked       :boolean          default(TRUE), not null
#  last_message_at       :datetime
#  title                 :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  project_id            :uuid
#  project_repository_id :uuid
#  prompt_persona_id     :uuid
#  scope_project_id      :uuid
#  scope_ticket_id       :uuid
#  ticket_id             :uuid
#  user_id               :uuid
#
# Indexes
#
#  index_chats_on_last_message_at        (last_message_at)
#  index_chats_on_organisation_id        (organisation_id)
#  index_chats_on_project_id             (project_id)
#  index_chats_on_project_repository_id  (project_repository_id)
#  index_chats_on_prompt_persona_id      (prompt_persona_id)
#  index_chats_on_scope_project_id       (scope_project_id)
#  index_chats_on_scope_ticket_id        (scope_ticket_id)
#  index_chats_on_ticket_id              (ticket_id) UNIQUE WHERE (ticket_id IS NOT NULL)
#  index_chats_on_user_id                (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (project_repository_id => project_repositories.id)
#  fk_rails_...  (prompt_persona_id => prompt_personas.id) ON DELETE => nullify
#  fk_rails_...  (scope_project_id => projects.id) ON DELETE => nullify
#  fk_rails_...  (scope_ticket_id => tickets.id) ON DELETE => nullify
#  fk_rails_...  (ticket_id => tickets.id)
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

RSpec.describe Chat, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'associations' do
    # ⚠️ project_id is a COLUMN and NOT an association since projekt_chat_abbau.
    # Pinned as an absence, deliberately: a `belongs_to` left standing would advertise
    # a link no chat has, and step 5 of that plan drops the column one release later
    # (ignored_columns first, drop second). THIS is the line that changes that day.
    it 'carries project_id as a plain column, with no association behind it' do
      expect(described_class.reflect_on_association(:project)).to be_nil
      expect(described_class.column_names).to include('project_id')
    end

    it { is_expected.to have_many(:chatposts).order(created_at: :asc).dependent(:destroy) }

    it 'belongs to organisation through acts_as_tenant' do
      expect(described_class.reflect_on_association(:organisation)).to be_present
    end
  end

  # S1 (doc/persoenlicher_assistent_plan.md §5.1): a thread gets an owner. The column
  # is nullable on purpose: the backfill has to be able to leave an authorless
  # thread alone.
  describe 'ownership' do
    it 'has an optional owner' do
      expect(described_class.reflect_on_association(:user)).to be_present
      expect(described_class.reflect_on_association(:user).options[:optional]).to be true
    end

    # Turned around by projekt_chat_abbau, and this is the strengthening it brought:
    # org_thread_has_owner read `return if project_id.present? || user_id.present?`, so
    # while project threads existed an ownerless one was legal and the S1 backfill
    # depended on it. No thread carries a project any more, so the invariant binds
    # every row.
    it 'is INVALID without an owner, now that every thread is org-wide' do
      chat = described_class.new(organisation: organisation)
      chat.chatposts << build(:chatpost, chat: chat, organisation: organisation)

      expect(chat).not_to be_valid
      expect(chat.errors[:user]).to be_present
    end

    # One predicate, one owner: components must not re-derive `user_id?` under
    # another name (same reason the header of #org_thread? gives).
    it 'answers personal? from the owner, not from the surface' do
      owner = create(:user)

      expect(described_class.new(user: owner)).to be_personal
      expect(described_class.new(organisation: organisation)).not_to be_personal
    end
  end

  # Was: three examples on project_repository_belongs_to_project, the cross-project
  # guard on the focus-repository pin. projekt_chat_abbau removed the association and
  # the validation: with no chat carrying a project the guard could never pass again,
  # and a validation that always fails turns a dead column into a live error message.
  # The column stays for Tools::Base#pinned_repo_id, which reads the raw id nil-safe.
  describe 'project_repository_id is a column with no rule behind it' do
    it 'has no association and no validation, and accepts any value' do
      expect(described_class.reflect_on_association(:project_repository)).to be_nil
      expect(described_class.column_names).to include('project_repository_id')
    end
  end

  describe 'prompt_persona must be available to the org (security)' do
    let(:global_persona) { create(:prompt_persona, organisation: nil, key: 'overview') }
    let(:own_persona) { create(:prompt_persona, organisation: organisation, key: 'own') }
    let(:foreign_persona) do
      create(:prompt_persona, organisation: create(:organisation), key: 'foreign')
    end

    def build_chat_with(persona)
      chat = Chat.new(organisation: organisation, user: user, prompt_persona: persona)
      chat.chatposts.build(content: 'hi', role: 'user', organisation: organisation)
      chat
    end

    it 'rejects a persona belonging to another organisation' do
      chat = build_chat_with(foreign_persona)
      expect(chat).not_to be_valid
      expect(chat.errors[:prompt_persona]).to be_present
    end

    it 'allows a global persona (organisation_id NULL)' do
      expect(build_chat_with(global_persona)).to be_valid
    end

    it 'allows the org’s own persona' do
      expect(build_chat_with(own_persona)).to be_valid
    end

    it 'allows no persona (nil → default persona is used at answer time)' do
      expect(build_chat_with(nil)).to be_valid
    end

    it 'rejects an INACTIVE own-org persona (validation goes through available_for’s active filter)' do
      # Connects the two blocks: PromptPersona.available_for filters active: true,
      # and Chat#prompt_persona_available uses it. Dropping `active: true` from the
      # scope would make a deactivated persona selectable again — this breaks then.
      inactive = create(:prompt_persona, organisation: organisation, key: 'retired', active: false)
      chat = build_chat_with(inactive)
      expect(chat).not_to be_valid
      expect(chat.errors[:prompt_persona]).to be_present
    end
  end

  describe 'associations (persona)' do
    it { is_expected.to belong_to(:prompt_persona).optional }
  end

  # A pin is a stored column, not a standing answer. Both ways a persona stops
  # being in effect have to reach the thread pin as well, or a retired prompt
  # fragment keeps arriving in every answer of a chat nobody has touched since.
  # ChatResponseJob reads exactly this method for step 1 of its resolution.
  describe '#resolved_persona (the pin, while it is still in effect)' do
    let(:pinned) { create(:prompt_persona, organisation: nil, key: 'pinned') }

    def chat_pinned_to(persona)
      create(:chat, organisation: organisation, prompt_persona: persona)
    end

    it 'returns the pinned persona' do
      expect(chat_pinned_to(pinned).resolved_persona).to eq(pinned)
    end

    it 'returns nil when nothing is pinned' do
      expect(chat_pinned_to(nil).resolved_persona).to be_nil
    end

    it 'returns nil once the pinned persona is deactivated' do
      chat = chat_pinned_to(pinned)
      pinned.update!(active: false)

      expect(chat.reload.resolved_persona).to be_nil
    end

    # Superseded rather than retired: the org publishes its own row under the
    # pinned key, so `pickable_for` collapses to the org row and the pin points at
    # something that is no longer the persona behind that key.
    it 'returns nil once an organisation override supersedes the pinned persona' do
      chat = chat_pinned_to(pinned)
      create(:prompt_persona, organisation: organisation, key: 'pinned')

      expect(chat.reload.resolved_persona).to be_nil
    end
  end

  describe 'language whitelist' do
    described_class::LANGUAGES.each do |lang|
      it "accepts #{lang.inspect}" do
        chat = described_class.new(organisation: organisation, user: user, language: lang)
        chat.chatposts.build(content: 'Hi', role: 'user', organisation: organisation)
        expect(chat).to be_valid
      end
    end

    it 'accepts nil (no language set yet)' do
      chat = described_class.new(organisation: organisation, user: user, language: nil)
      chat.chatposts.build(content: 'Hi', role: 'user', organisation: organisation)
      expect(chat).to be_valid
    end

    %w[fr es DE En de_DE].each do |bad|
      it "rejects #{bad.inspect}" do
        chat = described_class.new(language: bad)
        chat.chatposts.build(content: 'Hi', role: 'user', organisation: organisation)
        expect(chat).not_to be_valid
        expect(chat.errors[:language]).to be_present
      end
    end
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:chatposts) }

    it 'is invalid without any chatposts' do
      chat = described_class.new(organisation: organisation)
      chat.chatposts = []

      expect(chat).not_to be_valid
      expect(chat.errors[:chatposts]).to be_present
    end

    # Turned around in S3a: project-less is a legitimate shape now (org-wide
    # thread), but ONLY with an owner -- the invariant moves the requirement
    # from :project to :user. The valid org-thread case lives in the S3a
    # describe below.
    it 'is invalid without an owner' do
      chat = described_class.new(organisation: organisation)
      chat.chatposts.build(content: 'Test', role: 'user', organisation: organisation)

      expect(chat).not_to be_valid
      expect(chat.errors[:user]).to be_present
    end
  end

  describe 'nested attributes' do
    it { is_expected.to accept_nested_attributes_for(:chatposts).allow_destroy(true) }

    it 'builds a chat with nested chatpost attributes' do
      chat = described_class.new(
        project_id: project.id,
        chatposts_attributes: [
          { content: 'Hello', role: 'user', user_id: user.id, organisation_id: organisation.id }
        ]
      )

      expect(chat).to be_valid
      expect(chat.chatposts.size).to eq(1)
      expect(chat.chatposts.first.content).to eq('Hello')
    end

    it 'rejects blank chatpost attributes' do
      chat = described_class.new(
        project_id: project.id,
        chatposts_attributes: [{ content: '' }]
      )

      expect(chat.chatposts).to be_empty
    end

    it 'accepts multiple nested chatposts' do
      Prosopite.pause do
        chat = described_class.new(
          project_id: project.id,
          chatposts_attributes: [
            { content: 'First', role: 'user', user_id: user.id, organisation_id: organisation.id },
            { content: 'Second', role: 'assistant', organisation_id: organisation.id }
          ]
        )

        expect(chat).to be_valid
        expect(chat.chatposts.size).to eq(2)
      end
    end

    it 'destroys chatposts via nested attributes when _destroy is set' do
      chat = create(:chat, organisation: project.organisation)
      chatpost = chat.chatposts.first

      chat.update!(
        chatposts_attributes: [
          { id: chatpost.id, _destroy: true },
          { content: 'Replacement', role: 'user', user_id: user.id, organisation_id: organisation.id }
        ]
      )

      expect(chat.reload.chatposts.where(id: chatpost.id)).to be_empty
    end
  end

  # These three used to pin the after_create/after_update chatlist broadcast. S1
  # removed it (see the dedicated describe below for why), so they now pin its
  # absence at the same three moments — create, update and destroy.
  describe 'callbacks' do
    %i[create update destroy].each do |moment|
      it "sends no chatlist broadcast on #{moment}" do
        chat = moment == :create ? build(:chat, organisation: project.organisation) : create(:chat, organisation: project.organisation)
        allow(chat).to receive(:broadcast_replace_to)

        case moment
        when :create then chat.save!
        when :update then chat.touch
        else chat.destroy!
        end

        expect(chat).not_to have_received(:broadcast_replace_to)
      end
    end
  end

  describe '#first_message' do
    it 'returns the first chatpost content truncated to 20 characters' do
      chat = create(:chat, organisation: project.organisation)
      chat.chatposts.first.update!(content: 'This is a very long message that exceeds the limit')

      expect(chat.first_message).to eq('This is a very lo...')
      expect(chat.first_message.length).to eq(20)
    end

    it 'returns full content when shorter than 20 characters' do
      chat = create(:chat, organisation: project.organisation)
      chat.chatposts.first.update!(content: 'Short')

      expect(chat.first_message).to eq('Short')
    end

    it 'returns full content when exactly 20 characters' do
      chat = create(:chat, organisation: project.organisation)
      chat.chatposts.first.update!(content: 'Exactly twenty char!')

      expect(chat.first_message).to eq('Exactly twenty char!')
    end

    it 'returns the i18n fallback when chatposts have nil content' do
      chat = create(:chat, organisation: project.organisation)
      chat.chatposts.first.update_column(:content, nil)

      expect(chat.first_message).to eq(I18n.t('models.chat.no_messages'))
    end

    it 'returns the i18n fallback when there are no chatposts' do
      chat = create(:chat, organisation: project.organisation)
      chat.chatposts.delete_all

      expect(chat.first_message).to eq(I18n.t('models.chat.no_messages'))
    end

    it 'returns the first chatpost by created_at order' do
      chat = create(:chat, organisation: project.organisation)
      chat.chatposts.first.update!(content: 'First message')

      create(:chatpost, chat: chat, content: 'Second message', organisation: organisation,
                        created_at: 1.minute.from_now)

      expect(chat.first_message).to eq('First message')
    end
  end

  # S3c T1: the same label for a whole list, in one query. The per-record path
  # above and this one MUST agree -- they name the same thing on two surfaces
  # (the project chat's session list and the assistant panel's history).
  describe '.list_labels_for' do
    it 'returns the first message of each thread, keyed by chat id' do
      first  = create(:chat, organisation: project.organisation)
      second = create(:chat, organisation: project.organisation)
      first.chatposts.first.update!(content: 'Frage im ersten Verlauf')
      second.chatposts.first.update!(content: 'Frage im zweiten')

      labels = described_class.list_labels_for([first, second])

      expect(labels[first.id]).to eq(first.first_message)
      expect(labels[second.id]).to eq(second.first_message)
    end

    it 'truncates exactly like #first_message does' do
      chat = create(:chat, organisation: project.organisation)
      chat.chatposts.first.update!(content: 'This is a very long message that needs truncating')

      expect(described_class.list_labels_for([chat])[chat.id]).to eq(chat.first_message)
    end

    # The whole reason the method exists: the earliest post, not any post. With
    # the ordering dropped, Postgres is free to hand back the LAST one and the
    # list would name threads after whatever was said most recently.
    it 'takes the EARLIEST post of a thread, not an arbitrary one' do
      chat = create(:chat, organisation: project.organisation)
      chat.chatposts.first.update!(content: 'Zuerst gefragt')
      create(:chatpost, chat: chat, content: 'Danach gesagt', organisation: organisation,
                        created_at: 1.minute.from_now)

      expect(described_class.list_labels_for([chat])[chat.id]).to eq('Zuerst gefragt')
    end

    # The label is truncated in SQL, so the cost of the full column never shows
    # up in the RESULT -- that equivalence is the whole point. What it does show
    # up in is the boundary: LEFT(content, n) instead of n+1 hands Ruby exactly
    # n characters, #truncate leaves those alone, and a message of n+1 characters
    # comes back whole on this path while #first_message shortens it.
    describe 'agreeing with #first_message around the truncation boundary' do
      [
        ['one below the limit', Chat::LIST_LABEL_LENGTH - 1],
        ['exactly at the limit', Chat::LIST_LABEL_LENGTH],
        ['one above the limit',  Chat::LIST_LABEL_LENGTH + 1],
        ['far above the limit',  Chat::LIST_LABEL_LENGTH * 5]
      ].each do |name, length|
        it "matches #first_message for a message #{name} (#{length} chars)" do
          chat = create(:chat, organisation: project.organisation)
          chat.chatposts.first.update!(content: 'a' * length)

          expect(described_class.list_labels_for([chat])[chat.id]).to eq(chat.reload.first_message)
        end
      end

      it 'agrees on multibyte content too, where LEFT must count characters' do
        chat = create(:chat, organisation: project.organisation)
        chat.chatposts.first.update!(content: 'ä' * (Chat::LIST_LABEL_LENGTH + 1))

        expect(described_class.list_labels_for([chat])[chat.id]).to eq(chat.reload.first_message)
      end
    end

    # The reason the boundary above holds: the column is cut in the database, so
    # an unpaginated list of long first messages never hauls them into memory.
    # Asserted on the statement because by construction it cannot be asserted on
    # the result.
    it 'cuts the column in SQL rather than hauling the whole text over' do
      chat = create(:chat, organisation: project.organisation)

      statements = []
      counter = lambda do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        described_class.list_labels_for([chat])
      end

      expect(statements.join).to include("LEFT(content, #{Chat::LIST_LABEL_LENGTH + 1})")
    end

    it 'answers an empty list without asking the database' do
      expect { described_class.list_labels_for([]) }.not_to change(Chatpost, :count)
      expect(described_class.list_labels_for([])).to eq({})
    end

    # One query for the whole list is the point. Two threads that cost two
    # queries would be the N+1 this replaces.
    # Cross-tenant isolation. The method is handed IDS, and ids are the one thing
    # a caller can get wrong: `own_threads` scopes them today, but a future caller
    # with a list from somewhere else must not be able to pull a foreign
    # organisation's first message out of this. Chatpost is acts_as_tenant, so the
    # answer is empty rather than leaked -- pinned here, because a `.unscoped`
    # added for a "performance fix" would silently turn that around.
    it 'never labels a thread from another organisation, even when handed its id' do
      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) do
        chat = create(:chat, :org_thread, organisation: other_org, user: create(:user))
        chat.chatposts.first.update!(content: 'Fremde Frage')
        chat
      end

      labels = described_class.list_labels_for([foreign])

      expect(labels).to be_empty
      expect(labels.values).not_to include(a_string_including('Fremde'))
    end

    # The truncation boundary, on the bulk path. #first_message has its own
    # absolute examples; without these two the bulk path could drift by a
    # character and only the "behaves like #first_message" comparison would hold
    # it -- and that one is green as long as BOTH are wrong.
    describe 'at the truncation boundary' do
      def label_for(content)
        chat = create(:chat, organisation: project.organisation)
        chat.chatposts.first.update!(content: content)
        described_class.list_labels_for([chat])[chat.id]
      end

      # An ABSOLUTE pin, deliberately next to the relative ones below. Those move
      # with the constant, so they prove the mechanism and not the value: with
      # LIST_LABEL_LENGTH raised to 21 they stay green. The length is a design
      # decision (the panel is 380px by default), so a change to it should have to
      # walk past a test that spells the result out.
      it 'names a long thread by its first 20 characters, ellipsis included' do
        expect(label_for('Dies ist eine ziemlich lange Frage')).to eq('Dies ist eine zie...')
      end

      it 'leaves a label of exactly LIST_LABEL_LENGTH untouched' do
        content = 'A' * described_class::LIST_LABEL_LENGTH

        expect(label_for(content)).to eq(content)
      end

      it 'truncates one character more, ellipsis included in the length' do
        label = label_for('A' * (described_class::LIST_LABEL_LENGTH + 1))

        expect(label.length).to eq(described_class::LIST_LABEL_LENGTH)
        expect(label).to end_with('...')
      end
    end

    it 'costs ONE query regardless of how many threads it is given' do
      chats = Array.new(3) { create(:chat, organisation: project.organisation) }

      queries = 0
      counter = lambda do |_name, _start, _finish, _id, payload|
        queries += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION])
      end

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        described_class.list_labels_for(chats)
      end

      expect(queries).to eq(1)
    end
  end

  describe 'chatpost ordering' do
    it 'returns chatposts ordered by created_at ascending' do
      chat = create(:chat, organisation: project.organisation)
      first_post = chat.chatposts.first

      second_post = create(:chatpost, chat: chat, content: 'Second', organisation: organisation,
                                      created_at: 1.minute.from_now)
      third_post = create(:chatpost, chat: chat, content: 'Third', organisation: organisation,
                                     created_at: 2.minutes.from_now)

      expect(chat.chatposts.reload).to eq([first_post, second_post, third_post])
    end
  end

  describe 'dependent destroy' do
    it 'destroys the single chatpost when the chat is destroyed' do
      chat = create(:chat, organisation: project.organisation)
      chatpost_ids = chat.chatpost_ids

      expect { chat.destroy! }.to change(Chatpost, :count).by(-1)
      expect(Chatpost.where(id: chatpost_ids)).to be_empty
    end

    it 'cascades to all chatposts even when a system chatpost coexists with others' do
      # Regression guard: Chatpost#destroy has a guard that blocks directly
      # initiated deletion of a system message (when further posts exist).
      # With dependent: :destroy this guard must NOT take effect — otherwise the
      # chat is left with orphaned chatposts. Detected via destroyed_by_association.
      chat = create(:chat, organisation: project.organisation)
      create(:chatpost, chat: chat, content: 'Extra', role: 'user', organisation: organisation)
      chat.reload

      expect { chat.destroy! }.to change(Chatpost, :count).by(-2).and change(Chat, :count).by(-1)
    end
  end

  # ONE kind of thread since projekt_chat_abbau. The scope stays because it is the
  # term the callers ask -- and Chats::LegacyThreadPurge needs its counterpart askable
  # until step 5 empties and drops the column -- but it now matches every row.
  describe 'thread scopes' do
    let!(:thread) { create(:chat, organisation: organisation, user: user) }

    it '.org_threads returns every thread, because every thread is one' do
      expect(described_class.org_threads).to contain_exactly(thread)
    end

    it 'has no .project_threads any more' do
      expect(described_class).not_to respond_to(:project_threads)
    end
  end

  # S1 removed the chatlist broadcast entirely (assistant plan §10, R-H3).
  #
  # It replaced the WHOLE session list of a project and pushed it to a
  # project-wide stream, so after ownership it would have carried every colleague's
  # thread titles to everyone watching. Filtering was not the answer either: the
  # stream is keyed by project, a per-person list needs a per-person stream, and
  # there was nobody to serve. Measured before removing: no `turbo_stream_from` in
  # the app subscribes to `<project>_chatlist` — the only two chat subscriptions are
  # the per-chat post stream and the viewer stream. Every chat create and update
  # rendered the component, queried the project's threads, and sent it into the void.
  # There used to be a second assertion here, over _create_callbacks, and it could not
  # fail: after_create_commit registers in _commit_callbacks, and its filter is a Proc
  # whose to_s is "#<Proc:0x…>", never the method name. Removed rather than repaired —
  # the respond_to? check and the behavioural example below are the ones that bite.
  describe 'no chatlist broadcast (removed in S1)' do
    it 'does not define the method any more' do
      expect(described_class.new.respond_to?(:broadcast_chatlist, true)).to be false
    end

    # The behavioural half: the method could come back under another name. Creating
    # and renaming a thread must send nothing at all.
    it 'sends no turbo stream when a thread is created or renamed' do
      chat = build(:chat, organisation: organisation)
      allow(chat).to receive(:broadcast_replace_to)

      chat.save!
      chat.update!(title: 'Umbenannt')

      expect(chat).not_to have_received(:broadcast_replace_to)
    end
  end

  describe 'multi-tenancy' do
    it 'scopes chats to the current tenant' do
      other_org = create(:organisation)

      ActsAsTenant.with_tenant(organisation) { create(:chat) }
      ActsAsTenant.with_tenant(other_org) { create(:chat) }

      ActsAsTenant.with_tenant(organisation) do
        expect(described_class.count).to eq(1)
      end

      ActsAsTenant.with_tenant(other_org) do
        expect(described_class.count).to eq(1)
      end
    end

    it 'sets the organisation from the tenant on create' do
      chat = create(:chat, organisation: project.organisation)

      expect(chat.organisation).to eq(organisation)
    end
  end

  # ===========================================================================
  # S3a: org-wide threads (doc/persoenlicher_assistent_plan.md §5.1)
  # ===========================================================================
  #
  # An org-wide thread has NO project by definition. One invariant keeps the
  # shape closed, enforced twice (model validation + DB check constraint
  # chats_org_thread_requires_user): a project-less thread always has an owner --
  # otherwise an org-wide SHARED thread would arrive through the back door that
  # L2 rules out. (Its sibling "a ticket thread always has a project" went with
  # the ticket thread in S4-T1.)
  describe 'org-wide threads (S3a)' do
    let(:owner) { user }

    def build_org_thread(attrs = {})
      chat = described_class.new({ user: owner, organisation: organisation }.merge(attrs))
      chat.chatposts.build(content: 'Frage', user: owner, organisation: organisation)
      chat
    end

    it 'accepts a project-less thread with an owner' do
      expect(build_org_thread).to be_valid
    end

    # Trivially true since projekt_chat_abbau; the negative half went with the kind of
    # thread that could answer false. Kept as the ONE predicate callers ask, so the day
    # step 5 drops the column there is one place to change.
    it 'answers org_thread? from project_id (ONE predicate, no re-derivation)' do
      expect(build_org_thread).to be_org_thread
    end

    it 'refuses a project-less thread without an owner (model validation)' do
      chat = build_org_thread(user: nil)

      expect(chat).not_to be_valid
      expect(chat.errors[:user]).to be_present
    end

    it 'is backed by a DB check constraint for the owner invariant' do
      chat = build_org_thread(user: nil)

      expect { chat.save(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid, /chats_org_thread_requires_user/)
    end

    # R-H3: the S1 review removed the project-based chatlist broadcast, and the
    # remaining Chatpost broadcasts build their stream names from the CHAT. This
    # pins that no broadcast (or any other commit callback) in the chain still
    # walks chat.project -- the first org thread must not crash after commit.
    it 'creates an org thread without raising (R-H3)' do
      expect do
        create(:chat, :org_thread, organisation: organisation, user: owner)
      end.to change(described_class, :count).by(1)
    end
  end
  # S3a T5: the scope chip's column. Everything here is behaviour, not schema
  # decoration -- the whole "a chosen project that disappears widens back" design
  # rests on it, and none of it had a test.
  describe 'scope_project (T5)' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user) }

    around do |example|
      ActsAsTenant.with_tenant(organisation) { example.run }
    end

    let(:project) { create(:project, organisation: organisation) }

    def org_thread(**attrs)
      create(:chat, :org_thread, organisation: organisation, user: user, **attrs)
    end

    # Category: defaults as a contract. NOT set through the factory -- that would
    # test the factory. A thread with no chip must reach the full reach, and NULL
    # is what says so.
    it 'defaults to NULL, which is what "all your projects" means' do
      expect(org_thread.reload.scope_project_id).to be_nil
    end

    it 'holds the chosen project' do
      expect(org_thread(scope_project: project).reload.scope_project).to eq(project)
    end

    # Category: cascade. THE test of this slice's design. on_delete: :nullify is
    # what makes a deleted project widen the thread back instead of taking the
    # conversation with it. Turned into :cascade by a future migration, deleting a
    # project would silently delete personal chat histories -- and this is the only
    # place that would notice.
    describe 'when the chosen project is deleted' do
      it 'keeps the thread and clears the choice (DB-level ON DELETE SET NULL)' do
        chat = org_thread(scope_project: project)

        expect { project.destroy! }.not_to change(described_class, :count)
        expect(chat.reload.scope_project_id).to be_nil
      end

      # Bypasses Rails entirely, so it holds for a raw DELETE, a data migration or
      # a psql session -- the paths a dependent:/callback answer would miss.
      it 'holds even when Rails is not in the loop' do
        chat = org_thread(scope_project: project)

        ActiveRecord::Base.connection.execute("DELETE FROM projects WHERE id = '#{project.id}'")

        expect(chat.reload.scope_project_id).to be_nil
      end
    end

    # Category: cross-tenant isolation, and the gap this audit found. Chat already
    # carries THREE "defense in depth" invariants of exactly this shape
    # (project_repository, prompt_persona, ticket) -- each there because a crafted
    # form must not point the chat at something from another organisation.
    # scope_project was the fourth column of that shape and had none: the write
    # path checked it, the model did not, so anything writing around the
    # controller (console, import, a second controller later) could set it.
    describe 'cross-organisation invariant' do
      it 'refuses a project from another organisation' do
        foreign = ActsAsTenant.with_tenant(create(:organisation)) do |other|
          create(:project, organisation: other)
        end

        chat = build(:chat, :org_thread, organisation: organisation, user: user, scope_project: foreign)

        expect(chat).not_to be_valid
        expect(chat.errors[:scope_project]).to be_present
      end

      it 'accepts a project of its own organisation' do
        expect(build(:chat, :org_thread, organisation: organisation, user: user,
                                         scope_project: project)).to be_valid
      end

      it 'accepts no project at all' do
        expect(build(:chat, :org_thread, organisation: organisation, user: user)).to be_valid
      end
    end
  end
  # Bezugs-Sammlung S1 (§4.2): the reference collection. Same four categories as
  # scope_project above, and one category fewer than the ticket column had -- the
  # organisation check moved OFF the model on purpose, which is its own example
  # below.
  describe 'scope_references (S1)' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user) }

    around do |example|
      ActsAsTenant.with_tenant(organisation) { example.run }
    end

    let(:project) { create(:project, organisation: organisation) }
    let(:ticket) { create(:ticket, project: project, organisation: organisation) }

    def org_thread(**attrs)
      create(:chat, :org_thread, organisation: organisation, user: user, **attrs)
    end

    def entry_for(record)
      Assistant::ReferenceRegistry.stored_entry(type: record.class.name, id: record.id)
    end

    # Category: defaults as a contract. Not set through the factory, that would
    # test the factory. The EMPTY LIST is what "no reference" means, and there is
    # deliberately no second spelling of it: NULL is refused by the column.
    it 'defaults to the empty list, which is what "no reference" means' do
      expect(org_thread.reload.scope_references).to eq([])
    end

    it 'holds the referenced object as a type-and-id pair' do
      expect(org_thread(scope_ticket: ticket).reload.scope_references).to eq([entry_for(ticket)])
    end

    # The database floor under the model validation, in the shape of the
    # chats_org_thread_requires_user constraint next to it: it also holds for a
    # console, an import, or a second application writing this table.
    it 'refuses anything that is not a list, at the database level' do
      chat = org_thread

      expect do
        ActiveRecord::Base.connection.execute(
          "UPDATE chats SET scope_references = '{}'::jsonb WHERE id = '#{chat.id}'"
        )
      end.to raise_error(ActiveRecord::StatementInvalid, /chats_scope_references_is_array/)
    end

    # Category: form validation. Each of these is a shape the column must not
    # take, and each is reachable from a crafted form or a console.
    describe 'the shape of an entry' do
      # The model-level half of the array floor. The check constraint further up
      # catches a console; this catches a form or a caller handing over a Hash,
      # and the difference is a validation error instead of a StatementInvalid.
      it 'refuses anything that is not a list' do
        chat = org_thread
        chat.scope_references = { 'type' => 'Ticket', 'id' => ticket.id }

        expect(chat).not_to be_valid
        expect(chat.errors[:scope_references]).to be_present
      end

      it 'refuses an entry that is not a type-and-id pair' do
        chat = org_thread
        chat.scope_references = [{ 'type' => 'Ticket' }]

        expect(chat).not_to be_valid
        expect(chat.errors[:scope_references]).to be_present
      end

      # Fail-closed: what the registry does not know cannot be stored. Otherwise
      # a client could park arbitrary type names in the column and the only thing
      # keeping them harmless would be the read path.
      it 'refuses a type the registry does not know' do
        chat = org_thread
        chat.scope_references = [{ 'type' => 'Invoice', 'id' => SecureRandom.uuid }]

        expect(chat).not_to be_valid
      end

      # ⚠️ Without this an id that is not a UUID casts to NULL on the way into the
      # query and refuses SILENTLY instead of loudly
      # (reference_activerecord_casts_invalid_uuid_to_null).
      it 'refuses an id that is not a UUID' do
        chat = org_thread
        chat.scope_references = [{ 'type' => 'Ticket', 'id' => 'nicht-mal-eine-uuid' }]

        expect(chat).not_to be_valid
      end

      it 'refuses the same entry twice' do
        chat = org_thread
        chat.scope_references = [entry_for(ticket), entry_for(ticket)]

        expect(chat).not_to be_valid
      end

      # Boundary n-1 / n / n+1 around the limit. n-1 is the empty list above; n
      # and n+1 are here, and they are what makes "the limit is enforced" more
      # than a claim about one number.
      it 'accepts exactly MAX_REFERENCES entries and refuses one more' do
        max = Assistant::ReferenceRegistry::MAX_REFERENCES
        entries = Array.new(max + 1) { entry_for(create(:ticket, project: project, organisation: organisation)) }

        expect(build(:chat, :org_thread, organisation: organisation, user: user,
                                         scope_references: entries.first(max))).to be_valid

        chat = build(:chat, :org_thread, organisation: organisation, user: user, scope_references: entries)
        expect(chat).not_to be_valid
        expect(chat.errors[:scope_references]).to be_present
      end
    end

    # T-13 (plan §12). ⚠️ The validation is CONDITIONAL, and that is not a
    # performance nicety: an unconditional one breaks every foreign save on the
    # thread the moment a type is deregistered or an old entry sits in the list.
    # The scope chip writes through update! and would answer a 500 for a reason
    # that has nothing to do with it.
    #
    # Both halves in one example, because "the save goes through" is true of a
    # model with no validation at all: the same list is refused the moment the
    # save actually TOUCHES the column.
    it 'lets a foreign save through with an unknown entry in the list, but not a write of one' do
      chat = org_thread
      chat.update_column(:scope_references, [{ 'type' => 'Invoice', 'id' => SecureRandom.uuid }])

      expect { chat.reload.update!(scope_project_id: project.id) }.not_to raise_error

      expect(chat.reload.update(scope_references: [{ 'type' => 'Invoice', 'id' => SecureRandom.uuid }])).to be(false)
    end

    # T-8 (plan §12). The FK cascade that answered this for the old column is
    # gone -- a JSON list has no foreign key -- and the answer moved into the read
    # path, which is the same answer for a deleted object, an unreachable one and
    # a deregistered type.
    #
    # Two claims, and the second is the one a naive reading misses: the thread
    # survives (a reference must never take a conversation with it), and the entry
    # leaves NO trace, not even the id.
    describe 'when the referenced object is deleted' do
      # ⚠️ Both cells give the asker admin rights and anchor the POSITIVE half
      # first. With a member who may read nothing, #references is empty before
      # the destroy as well, and "resolves to nothing" is then true of any actor
      # -- the first version of the cell below had exactly that shape and stayed
      # green with the destroy deleted.
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation,
                              role: create(:admin_role, organisation: organisation), active: true)
        end
      end

      it 'keeps the thread, and the entry resolves to nothing' do
        chat = org_thread(scope_ticket: ticket)
        expect(Lalabase::Tools::Scope.for(chat: chat, actor: user).references).to eq([ticket])

        expect { ticket.destroy! }.not_to change(described_class, :count)
        expect(chat.reload.scope_references).to eq([entry_for(ticket)])
        expect(Lalabase::Tools::Scope.for(chat: chat, actor: user).references).to be_empty
      end

      # T-8, second half, RE-AIMED by the review of #642. It used to say the dead
      # entry goes "at the next write", and a removal was a next write -- which
      # turned archiving a project (reversible) into deleting its references
      # (not). The place is only cleared when somebody asks for it: adding at the
      # limit. A removal leaves the rest of the column exactly as it was.
      it 'leaves the dead entry in the column when another one is removed' do
        chat = org_thread(scope_ticket: ticket)
        expect(Lalabase::Tools::Scope.for(chat: chat, actor: user).references).to eq([ticket])
        stored = entry_for(ticket)
        ticket.destroy!

        Actors::RemoveChatReference.call(chat: chat.reload, type: 'Ticket', id: SecureRandom.uuid,
                                         current_user: user)

        expect(chat.reload.scope_references).to eq([stored])
      end
    end

    # T-7 (plan §12). ⚠️ The organisation check that the ticket column carried is
    # deliberately NOT on this model any more (§4.2): a validation is form, not
    # rights, and it knows no asker. What has to hold instead is that a smuggled
    # entry can do NOTHING -- so this bypasses the validation entirely
    # (update_column) and asks the READ path.
    #
    # ⚠️ The foreign side grants EVERYTHING, or the example proves only that
    # acts_as_tenant works: the smuggled ticket sits in a project whose owner has
    # full admin rights over there, and the asker on this side is an admin too, so
    # neither refusal can come from a missing right.
    #
    # ⚠️ Measured, and worth stating because it is easy to misread this cell:
    # what refuses HERE is the PROJECT clause -- a foreign ticket lives in a
    # foreign project, and the area reach only ever holds this organisation's
    # projects. Deleting `organisation_id:` from the registry's reachable lambda
    # leaves this example green. The organisation clause is defence in depth, and
    # the cell that isolates it is the one below.
    describe 'a smuggled entry from another organisation' do
      it 'resolves to nothing, and names nothing' do
        other = create(:organisation)
        foreign_ticket = ActsAsTenant.with_tenant(other) do
          foreign_project = create(:project, organisation: other, name: 'Fremdes Kundenprojekt')
          foreign_user = create(:user)
          create(:membership, user: foreign_user, organisation: other,
                              role: create(:admin_role, organisation: other), active: true)
          create(:ticket, project: foreign_project, organisation: other, creator: foreign_user,
                          title: 'Streng vertraulich')
        end
        # And on THIS side the asker is an admin too, so a refusal cannot come
        # from a missing right.
        create(:membership, user: user, organisation: organisation,
                            role: create(:admin_role, organisation: organisation), active: true)

        chat = org_thread
        chat.update_column(:scope_references, [entry_for(foreign_ticket)])

        expect(Lalabase::Tools::Scope.for(chat: chat.reload, actor: user).references).to be_empty
      end

      # The isolating half, and the only construction in which the organisation
      # clause is the thing that answers: a row whose PROJECT is reachable here
      # while the row itself belongs elsewhere. It is a data-integrity violation
      # rather than an everyday state, which is exactly what defence in depth is
      # for -- a botched move between organisations, an import, a console.
      #
      # Without it the clause is untested: with the project filter alone every
      # foreign object is already out of reach, so the example above stays green
      # when the clause is deleted (measured).
      it 'refuses a row of another organisation even when its project is reachable here' do
        create(:membership, user: user, organisation: organisation,
                            role: create(:admin_role, organisation: organisation), active: true)
        other = create(:organisation)
        smuggled = create(:ticket, project: project, organisation: organisation, title: 'Umgezogen')
        smuggled.update_column(:organisation_id, other.id)

        chat = org_thread
        chat.update_column(:scope_references, [entry_for(smuggled)])
        chat.reload

        # ⚠️ WITHOUT an ambient tenant, and that is the whole point of the cell.
        # Under a set tenant acts_as_tenant refuses this row on its own, so the
        # clause under test is masked -- and the place this object is actually
        # built is a background job, where the tenant belongs to whoever ran last.
        # Measured: with a tenant set, deleting `organisation_id:` from the
        # registry lambda leaves this example green too.
        ActsAsTenant.without_tenant do
          expect(Lalabase::Tools::Scope.for(chat: chat, actor: user).references).to be_empty
        end
      end
    end
  end
end
