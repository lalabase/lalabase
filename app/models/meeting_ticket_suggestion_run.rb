# frozen_string_literal: true

# A fixed generation attempt. Results retain their identity even if an older worker
# deletes open suggestions during a rolling deployment. No private suggestion scope.
# == Schema Information
#
# Table name: meeting_ticket_suggestion_runs
#
#  id               :uuid             not null, primary key
#  error            :text             default(""), not null
#  instruction      :text             default(""), not null
#  meeting_title    :string           not null
#  project_title    :string           not null
#  result_truncated :boolean          default(FALSE), not null
#  retried_at       :datetime
#  results          :jsonb            not null
#  sources          :jsonb            not null
#  status           :string           default("queued"), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  chatpost_id      :uuid
#  job_id           :string           not null
#  meeting_id       :uuid             not null
#  organisation_id  :uuid             not null
#  project_id       :uuid             not null
#
# Indexes
#
#  index_meeting_ticket_suggestion_runs_on_chatpost_id      (chatpost_id) UNIQUE
#  index_meeting_ticket_suggestion_runs_on_job_id           (job_id) UNIQUE
#  index_meeting_ticket_suggestion_runs_on_meeting_id       (meeting_id)
#  index_meeting_ticket_suggestion_runs_on_organisation_id  (organisation_id)
#  one_active_ticket_suggestion_run                         (meeting_id) UNIQUE WHERE ((status)::text = ANY ((ARRAY['queued'::character varying, 'running'::character varying])::text[]))
#
# Foreign Keys
#
#  fk_rails_...  (chatpost_id => chatposts.id) ON DELETE => cascade
#  fk_rails_...  (meeting_id => meetings.id) ON DELETE => cascade
#  fk_rails_...  (organisation_id => organisations.id)
#
class MeetingTicketSuggestionRun < ApplicationRecord
  acts_as_tenant(:organisation)
  belongs_to :meeting
  belongs_to :chatpost, optional: true
  has_many :meeting_ticket_suggestions, dependent: :nullify

  enum :status, { queued: 'queued', running: 'running', succeeded: 'succeeded', failed: 'failed' }
  validates :job_id, :meeting_title, :project_title, presence: true

  def active?
    queued? || running?
  end

  def stale?
    active? && updated_at < Meeting::SUGGESTIONS_STALE_AFTER.ago
  end

  def readable_by?(user)
    user && meeting.project_id == project_id && MeetingPolicy.new(user, meeting).show?
  end

  def writable_by?(user)
    readable_by?(user) && MeetingPolicy.new(user, meeting).update? && (!chatpost || !meeting.project.archived?)
  end

  def retryable?
    (failed? || stale?) && retried_at.nil?
  end

  # Include the actual permission-dependent presentation, never CSRF tokens.
  def presentation_digest(user, error: nil)
    readable = chatpost && ChatPolicy.new(user, chatpost.chat).show? && readable_by?(user)
    state = [I18n.locale, readable]
    if readable
      state += [error, cache_key_with_version, stale?, writable_by?(user), ProjectPolicy.new(user, meeting.project).area_access?(:tickets, :write)]
      state << meeting_ticket_suggestions.sort_by(&:id).map do |suggestion|
        [suggestion.cache_key_with_version, *[suggestion.similar_ticket, suggestion.created_ticket].map { |ticket| ticket && [ticket.cache_key_with_version, TicketPolicy.new(user, ticket).show?] }]
      end
    end
    Digest::SHA256.hexdigest(state.to_json)
  end

  # Failure belongs to the original task. Only meeting-page tasks also publish
  # their error to the shared meeting surface. All callers use the same lock.
  def mark_failed!(message: I18n.t('assistant_suggestions.interrupted'), from: %w[queued running])
    target = meeting
    target.with_lock do
      reload
      return false unless from.include?(status)
      return false if block_given? && !yield

      update!(status: :failed, error: message)
      attributes = { suggestions_creation_flag: false }
      attributes[:suggestions_creation_error] = message if chatpost_id.nil?
      target.update!(attributes)
      true
    end
  end

  def self.recover_for_meeting!(meeting)
    return unless meeting&.suggestions_creation_flag?

    run = find_by(meeting: meeting, status: %w[queued running])
    return unless run

    run.meeting = meeting
    run.recover_failed_delivery!
  end

  # A hard-killed worker is failed by Solid Queue rather than redelivered.
  def recover_failed_delivery!
    return unless active? && SolidQueue::Job.failed.where(active_job_id: job_id).exists?

    mark_failed! { SolidQueue::Job.failed.where(active_job_id: job_id).exists? }
  end

  def source_truncated?
    sources.values.any? { |source| source['text_truncated'] }
  end
end
