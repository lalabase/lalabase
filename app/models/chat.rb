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
#  index_chats_on_scope_ticket_id        (scope_ticket_id)
#  index_chats_on_user_id                (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (project_repository_id => project_repositories.id)
#  fk_rails_...  (prompt_persona_id => prompt_personas.id) ON DELETE => nullify
#  fk_rails_...  (scope_project_id => projects.id) ON DELETE => nullify
#  fk_rails_...  (scope_ticket_id => tickets.id) ON DELETE => nullify
#  fk_rails_...  (user_id => users.id)
#
class Chat < ApplicationRecord
  include ActionView::RecordIdentifier
  # belongs_to :prompt_persona + the "may this persona be attached" rule, shared
  # with ChatStylePreference so ONE place decides it.
  include PromptPersonaSelectable

  # Bezugs-Sammlung S1 (plan §4.4): the reference moved from ONE ticket column
  # into the scope_references list. The column stays in the database for one more
  # release: chats:backfill_scope_references MOVES what is still in it into the
  # list at every deploy and empties it in the same statement, so a rollback of
  # this slice HIDES the moved references under the old code (which reads NULL)
  # rather than losing them -- a redeploy shows them again. Ignored HERE so
  # nothing reads it any more, and the
  # association went with it: leaving `belongs_to :scope_ticket` behind an ignored
  # column makes chat.scope_ticket answer nil silently and breaks
  # includes(:scope_ticket) loudly, which is the worst of both.
  self.ignored_columns += %w[scope_ticket_id]

  # Alias of the canonical set (see Lalabase::Languages); kept for the validation + specs.
  LANGUAGES = Lalabase::Languages::SUPPORTED

  # How much of the first message names a thread in a session list. Short on
  # purpose: the assistant's list lives in a panel that is 380px wide by default.
  LIST_LABEL_LENGTH = 20

  acts_as_tenant(:organisation)
  # ⚠️ `project_id` is still a COLUMN and is deliberately NOT an association any
  # more. projekt_chat_abbau dissolved the per-project chat; every thread is
  # org-wide now, so the column is nil on every row and step 5 drops it one release
  # later (ignored_columns first, drop second -- a dropped column against running
  # old code is a 500 window). The predicates below read the attribute, which needs
  # no association, and a `belongs_to` left standing would advertise a link to a
  # project that no chat has.
  # S3a T5 (§9.3): the scope chip. NULL means "every project the asker may read".
  # Only ever a NARROWING -- Tools::Scope intersects it with the asker's rights,
  # and the write path (AssistantChatsController#update) refuses a project the
  # user may not read, so a stored id can never name something they cannot see.
  belongs_to :scope_project, class_name: 'Project', optional: true
  # The persona association + its availability rule live in
  # PromptPersonaSelectable (included above): NULL means "use the default
  # persona", and the persona biases how the assistant answers (Plan §6.3).
  # Optional: the OWNER of the thread (assistant plan §5.1, cut S1). NULL is a
  # legitimate state and not a gap waiting for a NOT NULL: a backfilled thread whose
  # first question has no author keeps NULL so an operator decides about it by hand.
  belongs_to :user, optional: true
  has_many :chatposts, -> { order(created_at: :asc) }, dependent: :destroy

  # ONE kind of chat since projekt_chat_abbau, and the scope stays although every row
  # written since then matches it. It is the term the callers ask -- ChatPolicy::Scope
  # and AssistantChatsController#set_chat both state the boundary through it -- and it
  # is not decoration: a database that still holds pre-cut rows WITH a project has rows
  # this excludes. The counterpart scope is gone (projekt_chat_abbau); LegacyThreadPurge
  # asks for those rows in raw SQL, because they are legacy rows and the model has no
  # business describing a shape it can no longer produce. Step 5 empties the column and
  # drops it, and this scope goes with it.
  scope :org_threads, -> { where(project_id: nil) }

  # Canonical "does this thread belong to somebody?" predicate: policy, scope and
  # components must ask ONE term rather than each re-deriving `user_id?` under its
  # own name, so a maintainer greps one term and finds every branch.
  def personal?
    user_id.present?
  end

  # Trivially true since projekt_chat_abbau, and kept until step 5 drops the column
  # underneath it. Callers still ask the term rather than the attribute, so the day
  # the column goes there is one place to delete instead of a grep.
  def org_thread?
    project_id.nil?
  end

  validates :language, inclusion: { in: LANGUAGES }, allow_nil: true
  # ⚠️ `project_repository_id` is a COLUMN with no association and no validation any
  # more (projekt_chat_abbau). It was the focus-repository pin, and it had no write path
  # anywhere in the app even before projekt_chat_abbau. With no chat carrying a
  # project, the guard that stood here (`project_repository.project_id == project_id`)
  # could never pass again -- a validation that always fails is worse than none,
  # because it turns a dead column into a live error message. Tools::Base still reads
  # the raw id nil-safe (pinned_repo_id), so the column keeps its meaning for the day
  # a pin comes back; step 5 decides whether it goes with project_id.
  # Defense in depth (same shape as the two above, S3a T5): the scope chip may
  # only ever point at a project of the chat's OWN organisation. The write path
  # (AssistantChatsController#update) already refuses anything off the user's own
  # list, but that is one door -- a console, an import or a second controller
  # later writes around it, and the chip PRINTS the project's name, which is
  # exactly what a member without access never gets to see.
  validate :scope_project_belongs_to_organisation
  # Bezugs-Sammlung S1 (plan §4.2): FORM only -- an Array of Hashes with exactly
  # `type` and `id`, a registered type, an id in UUID shape, no duplicates, at
  # most MAX_REFERENCES of them.
  #
  # ⚠️ What is deliberately NOT here is the organisation check the ticket column
  # carried (scope_ticket_belongs_to_organisation). A validation is form, not
  # rights: it knows no asker and cannot judge "resolvable" at all. A smuggled
  # foreign entry can do NOTHING -- the resolution (Tools::Scope#references) only
  # ever asks within the organisation AND the area reach, so an entry from
  # elsewhere resolves to nothing and leaves no trace. Deliberate relocation, with
  # its own example (spec/models/chat_spec.rb, "a smuggled foreign entry").
  #
  # ⚠️ `if: :scope_references_changed?` and not unconditional. An unconditional
  # validation breaks EVERY foreign save on the thread the moment a type is
  # deregistered or an old entry sits in the list: the scope chip writes through
  # update! (assistant_chats_controller.rb) and would answer a 500 for a reason
  # that has nothing to do with it. ChatResponseJob writes with update_columns and
  # would be unaffected, which only makes it quieter.
  validate :scope_references_well_formed, if: :scope_references_changed?
  # S3a invariant (plan §5.1), mirrored by a DB check constraint: a project-less
  # thread always has an owner -- otherwise an org-wide SHARED thread would exist,
  # which L2 rules out. Since projekt_chat_abbau that is every thread, and the
  # project_id half of the condition below is what step 5 removes with the column.
  validate :org_thread_has_owner

  accepts_nested_attributes_for :chatposts, reject_if: :all_blank, allow_destroy: true

  validates :chatposts, presence: true

  def first_message
    self.class.list_label(chatposts&.first&.content)
  end

  # The same label for a whole LIST of threads, in ONE query.
  #
  # #first_message above asks the association, which is a query per record: fine
  # for one chat, an N+1 the moment a list renders it (Prosopite fails the
  # request spec for the assistant's history list). `includes(:chatposts)` would
  # fix the count and cost far more than it saves -- it drags every post of every
  # thread into memory to print one truncated line each. DISTINCT ON is Postgres
  # saying "the earliest post per thread" and nothing else.
  #
  # LEFT rather than the bare column, and for the SAME reason: chatposts.content
  # is an unbounded text column, the first post is exactly the one somebody
  # pastes a paragraph into, and this list is deliberately unpaginated. n+1
  # characters is precisely enough -- #truncate only shortens above n, so a value
  # that arrives at n+1 truncates to the identical string the full column would
  # have produced, and anything at or below n arrives whole. Arel.sql because the
  # only interpolated value is the Integer constant above; nothing here is input.
  #
  # Returns { chat_id => label }; threads whose posts are gone are simply absent,
  # and the caller falls back to #first_message's own empty answer.
  def self.list_labels_for(chats)
    ids = Array(chats).map(&:id)
    return {} if ids.empty?

    Chatpost.where(chat_id: ids)
            .select(Arel.sql("DISTINCT ON (chat_id) chat_id, LEFT(content, #{LIST_LABEL_LENGTH + 1}) AS content"))
            .order(:chat_id, :created_at)
            .to_h { |post| [post.chat_id, list_label(post.content)] }
  end

  # ONE owner of how a thread is named in a list: the per-record path and the
  # bulk path above both come through here, so a change to the length or the
  # empty wording cannot apply to only one of the two surfaces.
  def self.list_label(content)
    content&.truncate(LIST_LABEL_LENGTH) || I18n.t('models.chat.no_messages')
  end

  # DOM ids shared by Chatpost broadcasts, the chat ViewComponents, and the
  # create.turbo_stream view — ONE source so the Turbo stream name can't drift
  # from its frame target (which would silently stop broadcasts from rendering).
  def chatposts_dom_id
    "#{dom_id(self)}_chatposts"
  end

  def chatpost_form_dom_id
    "#{dom_id(self)}_chatpost_form"
  end

  private

  # See the `validate` line above for WHY this is form and nothing else.
  def scope_references_well_formed
    list = scope_references
    return errors.add(:scope_references, :not_an_array) unless list.is_a?(Array)

    entries = list.map { |stored| Assistant::ReferenceRegistry.entry_from(stored) }
    return errors.add(:scope_references, :malformed_entry) if entries.any?(&:nil?)

    keys = entries.map { |entry| Assistant::ReferenceRegistry.key_for(**entry) }
    errors.add(:scope_references, :duplicate_entry) if keys.uniq.size != keys.size
    return unless keys.size > Assistant::ReferenceRegistry::MAX_REFERENCES

    errors.add(:scope_references, :too_many, count: Assistant::ReferenceRegistry::MAX_REFERENCES)
  end

  def scope_project_belongs_to_organisation
    return if scope_project_id.blank?
    return if scope_project&.organisation_id == organisation_id

    errors.add(:scope_project, :cross_organisation)
  end

  def org_thread_has_owner
    return if project_id.present? || user_id.present?

    errors.add(:user, :required_for_org_thread)
  end
end
