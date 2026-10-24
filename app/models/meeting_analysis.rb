# frozen_string_literal: true

# Slice 7a: one AI analysis of a meeting produced from a selectable prompt. A
# meeting can have arbitrarily many. Visibility is the Post pattern (E17):
# is_private + visible_to_user_id + a visible_to(user) scope + a consistency
# callback — a new analysis starts PRIVATE (prove, then publish). prompt_title and
# prompt_snapshot are frozen snapshots so the display title and the exact LLM input
# survive a prompt edit/deletion.
#
# The async LLM run (Meetings::AnalysisService/AnalysisJob) persists the Slice-4
# status pair (creation_flag "pending" + creation_error). The embedding pipeline
# columns exist for the Slice 7b wiring but carry no UI in 7a (the
# create_embeddings-without-UI pattern).
# == Schema Information
#
# Table name: meeting_analyses
#
#  id                       :uuid             not null, primary key
#  content                  :text             default(""), not null
#  creation_error           :text             default(""), not null
#  creation_flag            :boolean          default(FALSE), not null
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  include_in_search        :boolean          default(FALSE), not null
#  is_private               :boolean          default(TRUE), not null
#  prompt_snapshot          :text             not null
#  prompt_title             :string           not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  analysis_prompt_id       :uuid
#  creator_id               :uuid
#  meeting_id               :uuid             not null
#  organisation_id          :uuid             not null
#  visible_to_user_id       :uuid
#
class MeetingAnalysis < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :meeting
  belongs_to :creator, class_name: 'User', optional: true
  belongs_to :analysis_prompt, optional: true
  belongs_to :visible_to_user, class_name: 'User', optional: true

  # Search & chat fragments (Slice 7b wires the pipeline). delete_all mirrors
  # Meeting/Note: a cheap bulk delete, no per-row callbacks.
  has_many :fragments, as: :fragmentable, dependent: :delete_all

  # A pending run counts as "running" only within this window — the
  # Meeting#summary_generation_running? staleness valve, so a lost job (worker
  # outage) self-heals instead of bricking the section forever.
  STALE_AFTER = 10.minutes

  # Curated, product-maintained example prompts shown as chips in the assistant —
  # a starter set so a first-time user (empty prompt library) sees WHAT an analysis can
  # do. Keys only; the human label + prompt text live in i18n
  # (views.organisations.meetings.analyses.suggestions.<key>.{label,text}, DE+EN), so the
  # examples are translatable and editable without touching code. A chip merely PREFILLS
  # the free-text field (client-side) — no server/actor path change, and the user can edit
  # before running. Distinct from AnalysisPrompt (the org's OWN saved templates).
  # NB: `action_items` was removed here once "Aufgaben ableiten" became an actionable
  # ticket-suggestion mode instead of a prose
  # example; `followups` stays prose (next steps are often narrative, not ticket-shaped).
  SUGGESTED_PROMPT_KEYS = %w[decisions open_points risks summary followups].freeze

  validates :prompt_title, presence: true
  validates :prompt_snapshot, presence: true

  # Post-pattern visibility scopes (post.rb:60-67). visible_to filters to public
  # analyses PLUS the user's own private ones — the single query the list, the
  # policy scope and (Slice 7b) the fragment filter all share.
  scope :public_analyses, -> { where(is_private: false) }
  scope :private_analyses, -> { where(is_private: true) }
  scope :visible_to, lambda { |user|
    where('(is_private = false) OR (is_private = true AND visible_to_user_id = ?)', user&.id)
  }
  # Analyses whose run is pending AND still within the staleness window — backs the
  # controller's D11 idempotency guard (one run per meeting at a time).
  scope :running, -> { where(creation_flag: true).where('meeting_analyses.updated_at > ?', STALE_AFTER.ago) }

  # The analyses of `meeting` a user may see (public ∪ own private), eager-loaded and
  # newest-first — the ONE source for the results list, shared by the view helper
  # (visible_meeting_analyses) and the completion broadcast so the two cannot drift.
  def self.visible_for(meeting, user)
    where(meeting: meeting).visible_to(user)
                           .includes(:creator, :analysis_prompt)
                           .order(created_at: :desc)
  end

  # private ⇒ visible_to = creator, public ⇒ nil (post.rb:117). Runs before the
  # consistency validation below.
  before_validation :set_visible_to_user_on_private
  validate :private_visibility_consistency

  # Live-Cockpit (Option A): when an async run SETTLES (content or error written, the
  # pending flag cleared), push the finished result to the creator's OWN turbo stream —
  # NEVER a meeting-wide one, which would leak a private analysis to every viewer of the
  # meeting. Mirrors the summary broadcast infra but creator-scoped. It refreshes the
  # meeting result list only; analysis creation and its state now live in the assistant.
  after_update_commit :broadcast_completion
  # PII guarantee (embedding v2 PR 2): purge the sidecar embeddings of this analysis's
  # fragments BEFORE the dependent delete_all removes them (callback-free; the orphan
  # GC only ships in PR 3). Fires standalone AND via the Meeting-destroy :destroy
  # cascade. prepend: true — must beat the has_many dependent before_destroy callback,
  # which would otherwise delete the fragment rows our subselect needs.
  before_destroy :purge_fragment_content_embeddings, prepend: true

  def sources_publishable?
    Assistant::AnalysisSources.publishable?(context: source_context, meeting: meeting)
  end

  def private?
    is_private?
  end

  def public?
    !is_private?
  end

  def visible_to?(user)
    return true if public?
    return false if user.nil?

    visible_to_user_id == user.id
  end

  # Embedding pipeline contract (Codex-OV): the source is the content itself. A
  # METHOD, not a column (Ticket pattern) — the pipeline only checks respond_to?,
  # so there is no sync callback and no drift risk.
  def plain_text_version
    content
  end

  # E18: a private analysis is NEVER embedded; only a published + search-released
  # one. A derived method (no column) — the caller convention uses the predicate,
  # and AR generates none without a backing column, hence the alias. Unused in 7a
  # (search/embedding wiring is Slice 7b), but the contract is defined here.
  def create_embeddings
    !is_private && include_in_search
  end
  alias create_embeddings? create_embeddings

  # "Running" = pending flag set AND recently touched (see STALE_AFTER). Drives the
  # controller's re-run idempotency guard and the view spinner; a stale flag
  # self-heals so a fresh POST may re-run. Publish/search flips at a running
  # analysis are blocked (422) in the actor/controller (D11).
  def generation_running?
    creation_flag? && updated_at > STALE_AFTER.ago
  end

  private

  # See the before_destroy declaration: subselect the fragment ids (they still exist
  # because this runs BEFORE the dependent delete_all) and drop their sidecar rows.
  def purge_fragment_content_embeddings
    ContentEmbedding.purge_for(embeddable_type: 'Fragment', embeddable_ids: fragments.select(:id))
  end

  def broadcast_completion
    return if creator.nil? # no creator ⇒ no per-creator stream to push to
    return if creation_flag? # still running — wait for the run to settle
    return unless saved_change_to_creation_flag? || saved_change_to_content? || saved_change_to_creation_error?

    # A legacy job may finish after access changed while its creator still has
    # an open stream. Resolve a fresh user so request-level permission caches
    # from before the LLM call cannot authorize this later delivery.
    recipient = User.find_by(id: creator_id)
    return unless recipient

    # The meeting as stored, not the job's copy: a move (Actors::MoveMeeting)
    # may have committed while the model answered, and the creator's page in
    # the old project must not hear of it unless they read the new one.
    current_meeting = reload_meeting
    return unless current_meeting

    project_policy = ProjectPolicy.new(recipient, current_meeting.project)
    return unless project_policy.area_access?(:meetings, :read)

    # Only replace the stored-results list. The request-rendered assistant entry
    # remains outside this target, so an old queued job can finish without removing
    # the current creation action from the meeting page.
    # can_rerun asks the assistant gate for the CREATOR against this record's own
    # organisation: a job has no assistant_available? helper, and a retry button
    # for someone the gate excludes would only ever answer 403.
    broadcast_replace_to(
      current_meeting, recipient, :analyses,
      target: ActionView::RecordIdentifier.dom_id(current_meeting, :analyses_list),
      partial: 'organisations/meetings/analyses_list',
      locals: { meeting: current_meeting, analyses: self.class.visible_for(current_meeting, recipient),
                can_write: project_policy.area_access?(:meetings, :write),
                can_rerun: ChatPolicy.assistant_gate_open?(recipient, organisation) }
    )
  end

  def set_visible_to_user_on_private
    if is_private? && visible_to_user.nil?
      self.visible_to_user = creator
    elsif !is_private?
      self.visible_to_user = nil
    end
  end

  def private_visibility_consistency
    errors.add(:visible_to_user, :required_for_private) if is_private? && visible_to_user.nil?

    return unless !is_private? && visible_to_user.present?

    errors.add(:visible_to_user, :not_for_public)
  end
end
