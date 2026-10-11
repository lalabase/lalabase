# frozen_string_literal: true

# == Schema Information
#
# Table name: projects
#
#  id              :uuid             not null, primary key
#  archived_at     :datetime
#  description     :text
#  name            :string
#  repository      :text
#  settings        :jsonb            not null
#  system_kind     :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  archived_by_id  :uuid
#  organisation_id :uuid             not null
#
# Indexes
#
#  idx_projects_on_org_and_system_kind  (organisation_id,system_kind) UNIQUE WHERE (system_kind IS NOT NULL)
#  index_projects_on_archived_at        (archived_at)
#  index_projects_on_organisation_id    (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (archived_by_id => users.id)
#
class Project < ApplicationRecord
  include ProjectTrackable
  include OneLineText

  acts_as_tenant(:organisation)
  belongs_to :archived_by, class_name: 'User', optional: true

  has_many :ticket_attribute_definitions, dependent: :destroy
  has_many :tickets, dependent: :destroy
  has_many :ticket_bulk_runs, dependent: :delete_all
  has_many :notes, dependent: :destroy
  has_many :meetings, dependent: :destroy
  has_many :documents, dependent: :destroy
  has_many :time_sessions, dependent: :destroy
  has_many :project_permissions, dependent: :destroy
  has_many :permitted_users, through: :project_permissions, source: :user
  has_many :time_session_permissions, dependent: :destroy
  has_many :personal_access_token_projects, dependent: :destroy
  has_many :smart_folders, dependent: :destroy
  has_many :view_configurations, dependent: :destroy
  has_many :dashboard_configurations, dependent: :destroy
  has_many :codebase_import_files, dependent: :nullify
  has_many :project_repositories, dependent: :destroy
  has_many :documentation_sets, dependent: :destroy
  has_one  :project_layer4_vision, dependent: :destroy
  has_many :project_capabilities,  dependent: :destroy

  NAME_MAX_LENGTH = 255

  # What the normaliser drops: the control characters that are not whitespace
  # (whitespace, tab and newline included, becomes a space in the next step),
  # plus the invisible and direction-steering format characters. NOT the whole
  # \p{Cf} class: the zero-width non-joiner and joiner shape Persian, Hindi and
  # emoji sequences, the tag characters spell the England flag, the soft
  # hyphen is a hint.
  NAME_INVISIBLE_CHARS = /[\p{Cc}&&[^[:space:]]]|[\u200B\u200E\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]/

  # The name contract, in place of the former ASCII whitelist (which rejected
  # every umlaut): any printable text, ONE line, bounded. It is not display-only.
  # It reaches the assistant's system prompt (ChatResponseJob#scope_hint and
  # #reference_line, capped there through #one_line_name), the Subject header of
  # notification mails and the logs, so newlines and control characters must
  # never persist. Normalised on assignment, in this order: composed (NFC, so
  # a decomposed umlaut from a Finder copy is the same name as the typed one),
  # invisible characters dropped, THEN whitespace runs (newlines included)
  # collapsed to one space (the other way round, an invisible character between
  # two spaces leaves a double space), edges trimmed. A name that is nothing
  # but such characters comes out blank and fails presence. Never a path, slug
  # or shell argument.
  normalizes :name, with: lambda { |name|
    name.unicode_normalize(:nfc).gsub(NAME_INVISIBLE_CHARS, '').gsub(/[[:space:]]+/, ' ').strip
  }

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH },
                   uniqueness: { scope: :organisation_id }

  # The name as it may reach the model or a chip: one line, cut at the caller's
  # number (Ticket#one_line_title is the twin). Normalisation already made it one
  # line; the cap is what the callers add.
  def one_line_name(max:)
    one_line(name, max:)
  end

  # Preload nested associations before dependent :destroy to avoid N+1
  before_destroy :preload_nested_for_destroy, prepend: true
  # Callbacks to cleanup related data after project deletion
  after_destroy :cleanup_codebase_import_mappings

  # Archive scopes
  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  # Scope for optimized loading with attribute definitions
  scope :with_attribute_definitions, -> { includes(:ticket_attribute_definitions) }

  def archived?
    archived_at.present?
  end

  def archive!(user)
    update!(archived_at: Time.current, archived_by: user)
  end

  def unarchive!
    update!(archived_at: nil, archived_by: nil)
  end

  # Find users who have access to this project — delegates to ProjectAccessService.
  # Correctly accounts for no_access overrides.
  def users_with_access(action = :read, area = :tickets)
    AccessCheck::ProjectAccessService.users_with_access(self, action, area)
  end

  # Who may be ASSIGNED to (or made to watch) a ticket of this project: whoever
  # may read its tickets, among the ACTIVE members. users_with_access answers
  # who has access and keeps a deactivated member, whose permission rows stay;
  # it also decides notifications and what a move keeps, so the active rule
  # lives here and not there. The one source for the edit form
  # (TicketsHelper#assignable_users_for), the write check
  # (Ticket#assignable_user_ids) and the people of the board, the head menu and
  # the bulk panel (Tickets::BulkFields#people_options).
  def assignable_users
    users_with_access(:read, :tickets).where(id: organisation.active_users.select(:id))
  end

  # Deleting a project cascades into its notes, and ActionText::RichText declares
  # `belongs_to :record, touch: true` — so each note's rich text defers a touch that is
  # flushed at commit, after the note row is already gone. Notes carry lock_version, so
  # that zero-row UPDATE raises StaleObjectError instead of being a no-op, and the whole
  # deletion rolls back. Suppressing touches for the duration of the destroy is free:
  # every record that would be touched is being deleted anyway.
  #
  # ProjectDeletionJob wraps its own transaction the same way and must keep doing so —
  # the deferred touch fires at the OUTERMOST commit, which for the job is its
  # transaction, not this method.
  #
  # rubocop:disable Rails/ActiveRecordOverride -- the cop's alternatives cannot work here:
  # before_/around_/after_destroy all run INSIDE the transaction, while the offending touch
  # is flushed in before_commit. Only a wrapper that outlives the commit suppresses it.
  def destroy
    ActiveRecord::Base.no_touching { super }
  end
  # rubocop:enable Rails/ActiveRecordOverride

  private

  # Batch-preload ActionText rich texts (with ActiveStorage attachments) on child
  # records to avoid N+1 during cascading dependent: :destroy.
  # Taggings and fragments use dependent: :delete_all (no callbacks needed).
  def preload_nested_for_destroy
    loaded_tickets = tickets.to_a
    loaded_notes = notes.to_a
    all_records = loaded_tickets + loaded_notes
    return if all_records.empty?

    # Single query for all rich texts across record types.
    # Safe with UUID PKs (no cross-type ID collision risk).
    rich_texts = ActionText::RichText
                 .where(name: :content, record_id: all_records.map(&:id))
                 .includes(:embeds_attachments)
                 .to_a

    # Manually populate each record's association cache to prevent per-record queries
    rt_lookup = rich_texts.index_by { |rt| [rt.record_type, rt.record_id] }
    all_records.each do |record|
      rt = rt_lookup[[record.class.name, record.id]]
      association = record.association(:rich_text_content)
      association.target = rt
      association.loaded!
    end
  end

  # Cleanup CodebaseImportMappings related to this project's tickets
  def cleanup_codebase_import_mappings
    # Find all ticket IDs that belonged to this project
    ticket_ids = tickets.pluck(:id)
    return if ticket_ids.empty?

    # Find and delete mappings for these tickets
    mappings_to_delete = CodebaseImportMapping.where(
      entity_type: 'Ticket',
      local_id: ticket_ids
    )

    if mappings_to_delete.any?
      deleted_count = mappings_to_delete.count
      mappings_to_delete.delete_all
      Rails.logger.debug "Project cleanup: Deleted #{deleted_count} CodebaseImportMappings for project '#{name}' (ID: #{id})"
    end
  rescue StandardError => e
    Rails.logger.error "Project cleanup: Failed to delete CodebaseImportMappings for project #{id}: #{e.message}"
  end
end
