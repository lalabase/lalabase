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
#  scope_references      :jsonb            default([]), not null
#  scope_ticket_id       :uuid             (ignored)
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
#  index_chats_on_user_id                (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (project_repository_id => project_repositories.id)
#  fk_rails_...  (prompt_persona_id => prompt_personas.id) ON DELETE => nullify
#  fk_rails_...  (scope_project_id => projects.id) ON DELETE => nullify
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  # One kind of chat since projekt_chat_abbau: the org-wide personal thread. It has
  # no project by definition, so the organisation cannot be derived from one.
  #
  # Tenant first (second-review finding): a bare `organisation` association would
  # mint a NEW org and silently produce cross-tenant data in a spec that looks
  # tenant-scoped. Callers may still pass one explicitly.
  factory :chat do
    organisation { ActsAsTenant.current_tenant || association(:organisation) }
    # PERSISTED owner even under `build`: org_thread_has_owner reads `user_id`, and
    # validations run before Rails autosaves a belongs_to, so a merely BUILT user
    # leaves the id nil and the chat invalid. Before projekt_chat_abbau a built chat
    # satisfied that invariant through its project instead.
    user { association :user, strategy: :create }

    # Kept as a NO-OP so the ~90 examples that say `create(:chat, :org_thread, …)`
    # keep reading the way they were written: the trait described the only kind of
    # thread there is now. Deleting it would have turned one cut into a rewrite of
    # every chat spec in the suite, which is how a removal stops being reviewable.
    # Fair game to inline away later, one file at a time.
    trait :org_thread do
    end

    # Bezugs-Sammlung S1: the reference stopped being a column and became the
    # scope_references list. A transient and not a plain attribute, so the ~20
    # examples that say `scope_ticket: ticket` keep saying it -- what they are
    # ABOUT is a thread with a reference, and rewriting every one of them into
    # the stored JSON shape would have made the collection's own examples
    # unreadable and every other one noisier.
    #
    # The stored form comes from the registry, never spelled out here: two keys
    # written by hand in a factory are two keys that drift from the column.
    transient do
      scope_ticket { nil }
    end

    # Chat model has no title field but requires at least one chatpost
    after(:build) do |chat, evaluator|
      chat.chatposts << build(:chatpost, chat: chat, organisation: chat.organisation) unless chat.chatposts.any?

      next if evaluator.scope_ticket.blank?

      chat.scope_references = [Assistant::ReferenceRegistry.stored_entry(
        type: evaluator.scope_ticket.class.name, id: evaluator.scope_ticket.id
      )]
    end
  end
end
