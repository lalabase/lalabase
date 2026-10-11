# frozen_string_literal: true

# == Schema Information
#
# Table name: time_sessions
#
#  id                    :uuid             not null, primary key
#  billed                :boolean          default(FALSE), not null
#  billed_at             :datetime
#  customer_description  :text
#  deleted_at            :datetime
#  description           :text
#  duration              :integer          not null
#  invoice_number        :string
#  occurred_on           :datetime         not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  creator_id            :uuid             not null
#  meeting_id            :uuid
#  organisation_id       :uuid             not null
#  project_id            :uuid             not null
#  ticket_id             :uuid
#  time_session_group_id :uuid
#
# Indexes
#
#  index_time_sessions_active_project_occurred        (deleted_at,project_id,occurred_on)
#  index_time_sessions_on_billed                      (billed)
#  index_time_sessions_on_creator_id                  (creator_id)
#  index_time_sessions_on_creator_id_and_occurred_on  (creator_id,occurred_on)
#  index_time_sessions_on_customer_description        (customer_description) WHERE (customer_description IS NOT NULL)
#  index_time_sessions_on_deleted_at                  (deleted_at)
#  index_time_sessions_on_meeting_id                  (meeting_id)
#  index_time_sessions_on_organisation_id             (organisation_id)
#  index_time_sessions_on_project_billed              (project_id,billed_at)
#  index_time_sessions_on_project_id                  (project_id)
#  index_time_sessions_on_project_occurred            (project_id,occurred_on)
#  index_time_sessions_on_ticket_id                   (ticket_id)
#  index_time_sessions_on_ticket_occurred             (ticket_id,occurred_on)
#  index_time_sessions_on_time_session_group_id       (time_session_group_id)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (meeting_id => meetings.id) ON DELETE => nullify
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (ticket_id => tickets.id)
#  fk_rails_...  (time_session_group_id => time_session_groups.id)
#
class TimeSession < ApplicationRecord
  acts_as_tenant(:organisation)

  # The three mutually exclusive billing buckets: not in any billing group, in a
  # billing group but not yet billed, already billed. Used by the "Zeiten" status
  # filter (see TimeSessionFilterService#apply_billing_status_filter); passing all
  # three = "every state" (no filtering).
  #
  # The ORDER is the life cycle, left to right, and it is part of the contract:
  # every surface that shows the three side by side iterates THIS constant rather
  # than writing its own list, so the actionable backlog is always first and the
  # finished end always last. It used to run backwards in the filter pills and in
  # the overview table while the canonical order sat in a third place
  # (Overview::BillingOverviewComponent::STAGE_KEYS, now a pointer at this one).
  #
  # The words for these three keys have exactly ONE home:
  # views.time_sessions.billing_status.*, rendered through
  # TimeSessionsHelper#time_billing_state_label. Both halves are pinned by
  # spec/locales/time_list_billing_words_spec.rb and
  # spec/architecture/billing_state_vocabulary_guard_spec.rb.
  BILLING_STATUS_FILTERS = %w[without_billing in_billing billed].freeze

  # What the list shows when nobody has chosen a status: billed is hidden.
  #
  # ⚠️ An ABSENT status_filters parameter means this, not "all three". That is
  # why removing the status filter SETS all three states instead of clearing the
  # key (TimeSessionsHelper::TIME_FILTER_REMOVALS), and why the bare list address
  # is not a way back out of an empty list.
  #
  # Derived from the canonical list so the two cannot fall out of order, and
  # spelled here because two surfaces need the same fact: the mobile filter
  # badge counts a deviation from it, and since S7 the reset link exists only
  # while something deviates from it (decision E5). It was written out by hand
  # in the view before, which is one place too many for a rule.
  DEFAULT_HIDDEN_BILLING_STATUS = 'billed'
  DEFAULT_STATUS_FILTERS = (BILLING_STATUS_FILTERS - [DEFAULT_HIDDEN_BILLING_STATUS]).freeze

  # The fourth column of the status table (_billing_overview_panel): the sum of
  # the three buckets per project. Not a bucket (no session is "in" it), so it
  # stays out of the constant above, but it IS a column, and the row partial,
  # the table foot and the drill-down spec that follows every number of the
  # table all walk the same four. Spelled once here, or view and spec agree on
  # the word only by convention.
  BILLING_OVERVIEW_TOTAL = 'total'
  BILLING_OVERVIEW_COLUMNS = (BILLING_STATUS_FILTERS + [BILLING_OVERVIEW_TOTAL]).freeze

  # Query params that neutralise the time list's index defaults (current month,
  # billed hidden) for drill-down links that stand for a DEFINITE set: all three
  # buckets, every date, sum row on. The index defaults are right when a human
  # opens the list; a link that represents a reported number must not inherit
  # them, or the list shows a different set than the number promised. Custom
  # start_date/end_date merged ON TOP still win: the controller prefers custom
  # dates over date_range. ONE owner (Zweitreview F1) for all drill-down links
  # that stand for a total: the subject hours chip (SubjectTimeSummaryComponent),
  # the chat report citation (Neo::Chat::CitationListComponent) and the total
  # column of the billing overview panel (_billing_overview_panel).
  #
  # ⚠️ show_sum is GONE from here (02.09.2026). It used to switch on a boxed
  # total above the list, so a link standing for a number carried it; the result
  # row states the sum on every render now, the box is gone, and the parameter
  # with it. The two callers that had to write `.except(:show_sum)` -- the reset
  # and the empty state, neither of which is a drill-down for a number -- no
  # longer have to say anything at all.
  LIST_NEUTRAL_DRILLDOWN_PARAMS = {
    status_filters: BILLING_STATUS_FILTERS,
    date_range: 'all'
  }.freeze

  # The list parameters that name a SUBJECT. Two ids, deliberately separate
  # columns, and one filter as far as the reader is concerned: one "Bezug" pill,
  # one removal, one label.
  #
  # It is a list because S6 gave meetings a real filter. Before that the single
  # name `ticket_id` was written out in four places that all have to agree --
  # the filter service, the empty state's removable unit, the removal that a
  # project change performs, and the hidden fields that carry the filter across
  # a submit. A second subject type is exactly the change that turns four
  # hand-kept copies of one name into four chances to forget one, and forgetting
  # the last of them is silent: the filter simply falls off the next submit.
  SUBJECT_FILTER_PARAMS = %w[ticket_id meeting_id].freeze

  # Which of the three buckets a session falls into, from the two facts that decide
  # it. The SQL twin of this rule is TimeSessionFilterService#apply_billing_status_filter
  # (deliberate duplication: one is a WHERE clause, this one classifies rows already
  # fetched). Ruby-side classifiers (TimeSessionStatisticsService, the chat tool
  # SummarizeTimeSessions) go through here so the precedence "billed wins" is written once.
  def self.billing_bucket_for(billed:, grouped:)
    return 'billed' if billed
    return 'in_billing' if grouped

    'without_billing'
  end

  # Sort strategies for .group_by_subject. :title is one type-blind alphabetical
  # run — what you scan a time list for. :ticket_number is what a billing document
  # needs: numbered tickets ascending, the order a reader reconstructs an invoice
  # in, with meetings following them.
  SUBJECT_ORDERS = %i[title ticket_number].freeze

  # Relationships
  belongs_to :project
  # A session's subject is a Ticket OR a Meeting (Gespräche Slice 2), never both —
  # the XOR is enforced by the DB check constraint time_sessions_single_subject and
  # the #at_most_one_subject validation below. touch: keeps the subject's updated_at
  # fresh when its booked time changes (same contract as :ticket).
  belongs_to :ticket, optional: true, touch: true
  belongs_to :meeting, optional: true, touch: true
  belongs_to :creator, class_name: 'User'
  belongs_to :organisation
  belongs_to :time_session_group, optional: true

  # Tagging System
  include Taggable

  # Virtual attribute for time format
  attr_accessor :_duration_string

  # Callbacks
  before_validation :parse_duration_string

  # Soft Delete
  default_scope { where(deleted_at: nil) }

  # Scopes
  scope :by_time_session_group, ->(group_id) { where(time_session_group_id: group_id) }
  scope :without_group, -> { where(time_session_group_id: nil) }
  scope :grouped, -> { where.not(time_session_group_id: nil) }
  scope :billed, -> { where(billed: true) }
  scope :unbilled, -> { where(billed: false) }

  # The longest single booking: one day. Above it the value is a typo (a "1:30"
  # read as "130:0", a minutes figure pasted into an hours field) rather than
  # work; the bound holds on every surface (form, HTTP API, MCP tool) and keeps
  # a runaway figure away from the integer column's own limit.
  MAX_DURATION_MINUTES = 24 * 60

  # Validations
  validates :occurred_on, presence: true
  validates :duration, presence: true, numericality: { greater_than: 0 }
  # The ceiling applies to a NEW figure, not to every save: rows above it exist
  # from before the rule (there never was a check constraint), and a rule on
  # every save would freeze them, no description edit and no move in or out of
  # a billing group. Guarded on the change, so the row stays saveable until
  # somebody touches its duration.
  validates :duration, numericality: { less_than_or_equal_to: MAX_DURATION_MINUTES }, if: :duration_changed?
  validates :project_id, presence: true
  validates :creator_id, presence: true
  # validates :description, presence: { message: 'darf nicht leer sein' }
  validate :validate_duration_format
  validate :prevent_changes_when_billed
  validate :at_most_one_subject
  validate :subject_follows_project, on: :update, if: :will_save_change_to_project_id?

  # Getter for duration_string
  def duration_string
    return @_duration_string if defined?(@_duration_string) && @_duration_string.present?

    return '00:00' if duration.nil?

    hours = duration / 60
    minutes = duration % 60
    format('%02d:%02d', hours, minutes)
  end

  # Setter for duration_string
  def duration_string=(string)
    @_duration_string = string
  end

  # Formats a duration in minutes into the string format HH:MM
  def self.format_duration(minutes)
    return '00:00' if minutes.nil? || minutes.zero?

    hours = minutes / 60
    remaining_minutes = minutes % 60
    format('%02d:%02d', hours, remaining_minutes)
  end

  # Helper methods for billing status
  def grouped?
    time_session_group.present?
  end

  def editable?
    !billed?
  end

  # The subject of a session: its ticket OR its meeting (XOR — see
  # #at_most_one_subject), nil when the session hangs off the project alone. Single
  # source for a pair that used to be spelled out at every call site, which is how
  # the billing views kept reading .ticket only and rendered meeting-booked time as
  # "Ohne Ticket".
  def subject
    ticket || meeting
  end

  # Groups sessions by their subject for the grouped time list and the billing
  # views. Sessions without any subject land in the trailing nil group — never
  # merged with meeting-booked time, which is precisely the bug this replaces:
  # grouping by .ticket alone collapsed every meeting of a billing period into one
  # anonymous row with their durations summed.
  def self.group_by_subject(sessions, order: :title)
    raise ArgumentError, "unknown subject order: #{order.inspect}" unless SUBJECT_ORDERS.include?(order)

    sessions.group_by(&:subject).sort_by { |subject, _sessions| subject_sort_key(subject, order) }.to_h
  end

  # Fixed-width tuple so Ruby never compares an Integer against a String: slot 1
  # ranks the group, slots 2 and 3 order within a rank and are only ever compared
  # against a key of the same rank.
  def self.subject_sort_key(subject, order)
    return [2, 0, ''] if subject.nil? # the no-subject group always trails

    if order == :ticket_number && subject.is_a?(Ticket)
      # number stays nil until the after_create hook assigns it, hence to_i. The
      # title breaks ties: numbers are unique per PROJECT only, so a billing that
      # bundles two projects can hold two #5 — without the tiebreaker their order
      # would differ between two renderings of the same invoice annex.
      [0, subject.number.to_i, subject.title.to_s.downcase]
    elsif order == :ticket_number
      [1, 0, subject.title.to_s.downcase]
    else
      [0, 0, subject.title.to_s.downcase]
    end
  end
  private_class_method :subject_sort_key

  private

  # A session may be tied to at most one subject — a Ticket OR a Meeting, never
  # both (Gespräche Slice 2). This is the app-level guard for a clean form error;
  # the DB check constraint time_sessions_single_subject is the last line of
  # defense against a save that bypasses validations.
  def at_most_one_subject
    return unless ticket_id.present? && meeting_id.present?

    errors.add(:base, :single_subject)
  end

  # A booking that moves to another project cannot keep a ticket or meeting of
  # the old one (TimeSessionsController#move_to_requested_project).
  def subject_follows_project
    return if [ticket, meeting].compact.all? { |subject| subject.project_id == project_id }

    errors.add(:base, :subject_in_other_project)
  end

  # Prevents changes to billed sessions
  def prevent_changes_when_billed
    return unless billed? && changed? && !billed_changed?

    # Only allows changes to the billed status itself
    errors.add(:base, :billed_cannot_edit)
  end

  # Parses the duration_string input into the internal minutes representation
  # Supports various formats:
  # - HH:MM (e.g. "1:30")
  # - minutes (e.g. "90")
  # - decimal hours (e.g. "1.5")
  def parse_duration_string
    return if @_duration_string.blank?

    # Remove whitespace and replace commas with dots
    cleaned = @_duration_string.to_s.strip.gsub(',', '.')

    if cleaned.include?(':')
      # Format HH:MM. A trailing colon ("1:") splits into one element, a bare
      # ":" or "::" into none, and a nil half would raise inside
      # before_validation; read the missing half as zero and let the format
      # validation judge the string.
      hours, minutes = cleaned.split(':').map(&:to_i)
      self.duration = (hours.to_i * 60) + minutes.to_i
    elsif cleaned.include?('.')
      # Decimal hours (e.g. "1.5" for 1:30)
      hours = cleaned.to_f
      self.duration = (hours * 60).to_i
    else
      # Direct minutes
      self.duration = cleaned.to_i
    end
  end

  # Validates the format of the duration_string input
  # Allows:
  # - HH:MM (e.g. "1:30")
  # - minutes (e.g. "90")
  # - decimal hours (e.g. "1.5")
  def validate_duration_format
    return if @_duration_string.blank?

    valid_format = @_duration_string.match?(/^\s*(\d+(:?\d{0,2})?([.,]\d+)?|\d+:\d{1,2})\s*$/)
    return if valid_format

    errors.add(:duration_string, :invalid_format)
  end
end
