# frozen_string_literal: true

# Side-effect chain map: docs/architektur/seiteneffekt_ketten.md

# == Schema Information
#
# Table name: activities
#
#  id                :uuid             not null, primary key
#  action            :string           not null
#  attribute_changes :jsonb
#  key               :string           not null
#  parameters        :jsonb
#  secondary_type    :string
#  trackable_type    :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  actor_id          :uuid             not null
#  organisation_id   :uuid             not null
#  secondary_id      :uuid
#  trackable_id      :uuid             not null
#
# Indexes
#
#  index_activities_on_actor_and_time       (actor_id,created_at)
#  index_activities_on_actor_id             (actor_id)
#  index_activities_on_org_action_and_time  (organisation_id,action,created_at)
#  index_activities_on_org_key_and_time     (organisation_id,key,created_at)
#  index_activities_on_organisation_id      (organisation_id)
#  index_activities_on_secondary            (secondary_type,secondary_id)
#  index_activities_on_secondary_ref        (secondary_type,secondary_id)
#  index_activities_on_trackable            (trackable_type,trackable_id)
#  index_activities_on_trackable_and_time   (trackable_type,trackable_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (actor_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
class Activity < ApplicationRecord
  # Multi-Tenancy
  acts_as_tenant(:organisation)

  # Transient attribute to skip notifications. There is no broadcast to skip:
  # the two Turbo streams this model fed until 2026-10-02 had no subscriber
  # anywhere and were removed.
  attr_accessor :skip_notifications

  # Associations
  belongs_to :actor, class_name: 'User'
  belongs_to :trackable, polymorphic: true
  belongs_to :secondary, polymorphic: true, optional: true
  has_many :outbox_events, dependent: :delete_all

  # Validations
  validates :action, presence: true
  validates :key, presence: true

  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  # What a FEED shows (doc/ticket_bulk_edit_plan.md, D12): a bulk run is one
  # line on the project, and the tickets' own activities of that run stay out,
  # or two hundred rows saying the same thing bury everything else. A ticket's
  # timeline reads without this scope and keeps every row. Every reader that
  # shows a feed uses it (a guard spec checks).
  # A single-ticket run (D13, one ticket is a set of one) marks no member and
  # stays in the feed as today; only the members of a run of several are
  # hidden, whatever they hang on (a ticket's change, a project's "moved out",
  # a ticket's "deleted"; slice 7).
  scope :feed, -> { where("(activities.parameters->>'bulk_run_member') IS NULL") }
  scope :for_actor, ->(user) { where(actor: user) }
  scope :for_trackable, ->(object) { where(trackable: object) }
  scope :for_action, ->(action) { where(action: action) }
  scope :for_key, ->(key) { where(key: key) }
  scope :today, -> { where(created_at: Date.current.all_day) }
  # Time.current, not Date.current: Date#end_of_week is a DATE, and Rails binds it as
  # midnight, so the whole last day of the week fell outside the range. The scope was
  # correct six days out of seven and silently wrong on the seventh - which is also why
  # its spec only went red on a Sunday. Time#all_week ends at 23:59:59.999999, the same
  # shape the :today scope beside it already had via Date#all_day.
  scope :this_week, -> { where(created_at: Time.current.all_week) }

  # Scopes for specific activity types
  scope :creations, -> { for_action('created') }
  scope :updates, -> { for_action('updated') }
  scope :deletions, -> { for_action('deleted') }

  # Callbacks
  before_validation :set_key
  after_create_commit :create_notification_outbox_event

  # Helper Methods

  # Returns the display name of the action (i18n)
  def action_text
    I18n.t("activities.#{key}", default: key.tr('.', ' ').humanize.capitalize)
  end

  # Formatted message with actor and context
  def message(options = {})
    params_hash = (parameters || {}).symbolize_keys
    # Provide sensible defaults for templates that expect either :trackable or :display_name
    params_hash[:trackable] ||= trackable_display_name
    params_hash[:display_name] ||= trackable_display_name

    I18n.t(
      "activities.messages.#{key}",
      actor: actor&.full_name,
      **params_hash,
      **options
    )
  rescue I18n::MissingInterpolationArgument
    # Incomplete activity parameters must not crash the entire timeline.
    [actor&.full_name, action_text].compact.join(' — ')
  end

  # Returns the display name of the trackable object
  def trackable_display_name
    case trackable
    when Ticket
      "##{trackable.number} #{trackable.title}"
    when Project
      trackable.name
    else
      trackable.try(:title) || trackable.try(:name) || trackable.class.name
    end
  end

  # Icon for activity type
  def icon
    case action
    when 'created' then 'plus-circle'
    when 'updated' then 'pencil'
    when 'deleted' then 'trash'
    when 'assigned' then 'person-plus'
    when 'unassigned' then 'person-dash'
    when 'status_changed' then 'arrow-right-circle'
    when 'priority_changed' then 'exclamation-circle'
    when 'post_added' then 'chat-left-text'
    when 'moved' then 'arrow-right-square'
    when 'subscriber_added' then 'bi-person-plus'
    when 'subscriber_removed' then 'bi-person-dash'
    else 'circle'
    end
  end

  # CSS class for activity type
  def css_class
    case action
    when 'created' then 'text-success'
    when 'deleted' then 'text-danger'
    when 'assigned', 'unassigned' then 'text-info'
    when 'moved' then 'text-purple-600'
    when 'subscriber_added' then 'text-success'
    when 'subscriber_removed' then 'text-danger'
    else 'text-muted'
    end
  end

  # Bookkeeping columns that change alongside the real change but say
  # nothing a reader wants: the activity row already names the actor, so a
  # raw "Updater: <uuid>" line is noise (user report 05.09.2026). Filtered
  # on DISPLAY so historic activities heal too; Trackable additionally
  # stopped recording them.
  NOISE_CHANGE_ATTRIBUTES = %w[updater_id].freeze

  # Checks whether the activity contains changes worth showing
  def has_changes?
    formatted_changes.any?
  end

  # Returns formatted changes, keyed by display name. A nil value marks a
  # change with no old/new pair worth showing (a rich-text body, see
  # Trackable#rich_text_changed_attrs) - the action names it, the details
  # table skips it.
  def formatted_changes
    return {} if attribute_changes.blank?

    attribute_changes.except(*NOISE_CHANGE_ATTRIBUTES)
                     .reject { |_key, value| value.nil? }
                     .transform_keys { |name| change_label(name) }
  end

  # The display name of one changed field: what the model calls it
  # (activerecord.attributes.*), never the column. "Summary" stood in the
  # project feed while activerecord.attributes.ticket.summary already read
  # "Zusammenfassung" (user brief 10.09.2026). human_attribute_name still
  # humanizes a column it has no name for; that is the last resort, not the rule.
  def change_label(name)
    trackable_class&.human_attribute_name(name) || name.to_s.humanize
  end

  # GDPR-compliant helpers for user-related displays
  # These methods fetch user data dynamically from the references
  # instead of storing it in the activity parameters

  def assignee_display_name
    return nil unless %w[assigned unassigned].include?(action)

    secondary&.full_name || I18n.t('activities.deleted_user')
  end

  def subscriber_display_name
    return nil unless %w[subscriber_added subscriber_removed].include?(action)

    secondary&.display_name || secondary&.full_name || I18n.t('activities.deleted_user')
  end

  def post_author_display_name
    return nil unless action == 'post_added'

    secondary&.user&.full_name || I18n.t('activities.deleted_user')
  end

  def actor_display_name
    actor&.full_name || I18n.t('activities.deleted_user')
  end

  # Revised message method
  def detailed_message(options = {})
    params = parameters || {}

    case action
    when 'assigned'
      I18n.t('activities.messages.ticket.assigned',
             actor: actor_display_name,
             assignee: assignee_display_name,
             trackable: trackable_display_name,
             role: params['user_role'] || 'Mitglied',
             display_name: params['display_name'] || trackable_display_name)
    when 'unassigned'
      I18n.t('activities.messages.ticket.unassigned',
             actor: actor_display_name,
             assignee: assignee_display_name,
             trackable: trackable_display_name,
             display_name: params['display_name'] || trackable_display_name)
    when 'post_added'
      I18n.t('activities.messages.ticket.post_added',
             actor: post_author_display_name,
             trackable: trackable_display_name,
             excerpt: params['post_excerpt'])
    when 'moved'
      I18n.t('activities.messages.ticket.moved',
             actor: actor_display_name,
             trackable: trackable_display_name,
             from_project_name: params['from_project_name'],
             to_project_name: params['to_project_name'],
             display_name: params['display_name'] || trackable_display_name)
    when 'subscriber_added'
      I18n.t('activities.messages.ticket.subscriber_added',
             actor: actor_display_name,
             subscriber: subscriber_display_name,
             trackable: trackable_display_name,
             display_name: params['display_name'] || trackable_display_name)
    when 'subscriber_removed'
      I18n.t('activities.messages.ticket.subscriber_removed',
             actor: actor_display_name,
             subscriber: subscriber_display_name,
             trackable: trackable_display_name,
             display_name: params['display_name'] || trackable_display_name)
    when 'status_changed'
      # Defaults prevent a crash on legacy/seed data without from/to_status.
      I18n.t('activities.messages.ticket.status_changed',
             actor: actor_display_name,
             from_status: params['from_status'] || '—',
             to_status: params['to_status'] || '—',
             trackable: trackable_display_name,
             display_name: params['display_name'] || trackable_display_name)
    else
      message(options)
    end
  end

  private

  # The trackable's class without loading the record: naming a field needs
  # the model, not the object. nil for a type whose class is gone.
  def trackable_class
    association(:trackable).klass
  rescue NameError
    nil
  end

  def set_key
    self.key ||= "#{trackable_type.underscore}.#{action}" if trackable_type && action
  end

  def create_notification_outbox_event
    # Skip notifications if flag is set (e.g., for imported activities)
    return if skip_notifications

    # Create outbox event for asynchronous notification processing
    OutboxEvent.create_from_activity!(self)
  rescue StandardError => e
    Rails.logger.error "Failed to create outbox event for activity #{id}: #{e.message}"
    # Don't raise - outbox event creation shouldn't break the main activity creation
  end
end
