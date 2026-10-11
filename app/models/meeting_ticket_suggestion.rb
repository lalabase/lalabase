# frozen_string_literal: true

# == Schema Information
#
# Table name: meeting_ticket_suggestions
#
#  id                :uuid             not null, primary key
#  description       :text             default(""), not null
#  status            :integer          default(0), not null
#  title             :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  created_ticket_id :uuid
#  meeting_id        :uuid             not null
#  organisation_id   :uuid             not null
#  similar_ticket_id :uuid
#
# Indexes
#
#  index_meeting_ticket_suggestions_on_created_ticket_id      (created_ticket_id)
#  index_meeting_ticket_suggestions_on_meeting_id_and_status  (meeting_id,status)
#  index_meeting_ticket_suggestions_on_organisation_id        (organisation_id)
#  index_meeting_ticket_suggestions_on_similar_ticket_id      (similar_ticket_id)
#
# Foreign Keys
#
#  fk_rails_...  (created_ticket_id => tickets.id) ON DELETE => nullify
#  fk_rails_...  (meeting_id => meetings.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (similar_ticket_id => tickets.id) ON DELETE => nullify
#

# An AI-derived ticket suggestion for a meeting (Gespräche Slice 8, E22). A run
# creates `open` rows from the meeting's source; the user accepts one (→ a real
# Ticket via Actors::AcceptTicketSuggestion, recorded in created_ticket) or
# dismisses it. `similar_ticket` is the server-side similarity hint — a nearest
# existing ticket in the same project, computed ONLY from our own embeddings
# (never an LLM-supplied id — halluzination guard). accepted/dismissed rows are
# kept as history; a re-run replaces only the `open` ones.
class MeetingTicketSuggestion < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :meeting
  belongs_to :meeting_ticket_suggestion_run, optional: true
  # Both point at tickets under custom column names, both optional: the hint may be
  # absent (no match ≥ threshold) and created_ticket only exists once accepted.
  belongs_to :similar_ticket, class_name: 'Ticket', optional: true
  belongs_to :created_ticket, class_name: 'Ticket', optional: true

  enum :status, { open: 0, accepted: 1, dismissed: 2 }

  # Title is capped at 255 in the parse step (TicketSuggestionService); the model
  # guards the same invariant so a crafted write can't persist an oversized title.
  validates :title, presence: true, length: { maximum: 255 }

  # One conditional write shared by both authorized controller surfaces.
  def dismiss_if_open
    self.class.open.where(id: id, meeting_id: meeting_id).update_all(status: self.class.statuses[:dismissed], updated_at: Time.current)
  end
end
