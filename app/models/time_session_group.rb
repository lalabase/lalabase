# frozen_string_literal: true

# == Schema Information
#
# Table name: time_session_groups
#
#  id              :uuid             not null, primary key
#  billed          :boolean          default(FALSE), not null
#  billed_at       :datetime
#  description     :text
#  invoice_number  :string
#  name            :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  creator_id      :uuid             not null
#  organisation_id :uuid             not null
#
# Indexes
#
#  index_time_session_groups_on_creator_id                     (creator_id)
#  index_time_session_groups_on_org_and_invoice_number_unique  (organisation_id,invoice_number) UNIQUE WHERE (invoice_number IS NOT NULL)
#  index_time_session_groups_on_organisation_id                (organisation_id)
#  index_time_session_groups_on_organisation_id_and_billed     (organisation_id,billed)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
class TimeSessionGroup < ApplicationRecord
  include Trackable

  acts_as_tenant(:organisation)

  # Associations
  belongs_to :organisation
  belongs_to :creator, class_name: 'User'
  has_many :time_sessions, dependent: :nullify

  # Validations
  validates :name, presence: true
  validates :billed, inclusion: { in: [true, false] }
  validates :invoice_number, presence: true, if: :billed?
  validates :invoice_number, uniqueness: { scope: :organisation_id }, if: :invoice_number?

  # Scopes
  scope :billed, -> { where(billed: true) }
  scope :unbilled, -> { where(billed: false) }
  scope :ordered, -> { order(created_at: :desc) }

  # Callbacks
  before_save :set_billed_at
  before_save :normalize_billed_at_to_date

  # Instance methods
  def total_duration
    time_sessions.sum(:duration)
  end

  def total_duration_in_hours
    (total_duration / 60.0).round(2)
  end

  def mark_as_billed!(invoice_number)
    update!(billed: true, invoice_number: invoice_number, billed_at: Date.current.beginning_of_day)
  end

  def projects
    Project.joins(:time_sessions)
           .where(time_sessions: { time_session_group_id: id })
           .distinct
  end

  def project_names
    projects.pluck(:name).join(', ')
  end

  # Activity tracking helper methods
  def display_name
    name
  end

  private

  # Override from Trackable concern
  def track_specific_changes(changed_attrs)
    # Track billing status changes specially
    if changed_attrs.key?('billed')
      if billed?
        create_activity(
          action: 'marked_as_billed',
          parameters: {
            invoice_number: invoice_number,
            billed_at: billed_at,
            display_name: name
          }
        )
      else
        create_activity(
          action: 'marked_as_unbilled',
          parameters: {
            display_name: name,
            previous_invoice_number: changed_attrs['invoice_number']&.first
          }
        )
      end
    elsif billed? && (changed_attrs.key?('invoice_number') || changed_attrs.key?('name') || changed_attrs.key?('description'))
      # Track changes to billed groups separately
      create_activity(
        action: 'billed_data_changed',
        attribute_changes: changed_attrs,
        parameters: {
          display_name: name,
          warning_acknowledged: true
        }
      )
    else
      # Default update tracking
      create_activity(
        action: 'updated',
        attribute_changes: changed_attrs,
        parameters: activity_parameters_for_update
      )
    end
  end

  def activity_parameters_for_create
    {
      display_name: name,
      description: description,
      creator: creator.full_name
    }
  end

  def activity_parameters_for_update
    {
      display_name: name,
      billed_status: billed? ? 'abgerechnet' : 'nicht abgerechnet'
    }
  end

  def set_billed_at
    if billed_changed? && billed?
      # Set to current date only if billed_at is not already set
      self.billed_at = Date.current if billed_at.blank?
    elsif billed_changed? && !billed?
      self.billed_at = nil
    end
  end

  def normalize_billed_at_to_date
    # Ensure billed_at is always stored as beginning of day (date only)
    return unless billed_at.present? && billed_at.respond_to?(:beginning_of_day)

    self.billed_at = billed_at.to_date.beginning_of_day
  end
end
