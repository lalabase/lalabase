# frozen_string_literal: true

# One bulk run over tickets (doc/ticket_bulk_edit_plan.md, D8, slice 7): a
# change, a move or a delete (kind). What was done (change_list; not
# `changes`, which is ActiveRecord's own), what happened per ticket, with the
# previous values for a change, and whether the run was undone. The result
# line reads its partial results from here, "Rückgängig" reads the previous
# values from here (a change only), and an undo is a run of its own that
# points back (undo_of).
#
# results: { ticket_id => { 'ok' => true, 'number' => 12, 'before' => { field => value } }
#                      | { 'ok' => true, 'number' => 12, 'new_number' => 3 }        (move)
#                      | { 'ok' => true, 'number' => 12, 'title' => '...' }         (delete)
#                      | { 'ok' => false, 'number' => 12, 'error' => 'code' } }
# == Schema Information
#
# Table name: ticket_bulk_runs
#
#  id              :uuid             not null, primary key
#  change_list     :jsonb            not null
#  changed_count   :integer          default(0), not null
#  failed_count    :integer          default(0), not null
#  results         :jsonb            not null
#  undone_at       :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  project_id      :uuid             not null
#  undo_of_id      :uuid
#  user_id         :uuid
#
# Indexes
#
#  index_ticket_bulk_runs_on_organisation_id  (organisation_id)
#  index_ticket_bulk_runs_on_project_id       (project_id)
#  index_ticket_bulk_runs_on_undo_of_id       (undo_of_id)
#  index_ticket_bulk_runs_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (undo_of_id => ticket_bulk_runs.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#
class TicketBulkRun < ApplicationRecord
  acts_as_tenant :organisation

  belongs_to :organisation
  belongs_to :project
  belongs_to :user, optional: true
  belongs_to :undo_of, class_name: 'TicketBulkRun', optional: true
  has_one :undone_by, class_name: 'TicketBulkRun', foreign_key: :undo_of_id, dependent: :nullify, inverse_of: :undo_of

  # How long "Rückgängig" is offered (user, 08.09.2026): safe at any time,
  # because the undo checks every ticket first; limited so that a click a
  # week later, from the feed, is not a decision without its context.
  UNDO_WINDOW = 24.hours

  KIND_CHANGE = 'change'
  KIND_MOVE = 'move'
  KIND_DELETE = 'delete'
  KINDS = [KIND_CHANGE, KIND_MOVE, KIND_DELETE].freeze

  validates :kind, inclusion: { in: KINDS }

  scope :recent, -> { order(created_at: :desc) }

  def change?
    kind == KIND_CHANGE
  end

  def move?
    kind == KIND_MOVE
  end

  def delete?
    kind == KIND_DELETE
  end

  # The target of a move, as the run recorded it (the name, so the line reads
  # even after the project is renamed or gone).
  def target_project_name
    change_list.first&.dig('target_project_name').to_s
  end

  def undo?
    undo_of_id.present?
  end

  def undone?
    undone_at.present?
  end

  def ok_ticket_ids
    results.select { |_id, result| result['ok'] }.keys
  end

  def failed_results
    results.reject { |_id, result| result['ok'] }
  end

  def ok_numbers
    results.values.select { |result| result['ok'] }.map { |result| result['number'] }.compact
  end

  def before_for(ticket_id)
    results.dig(ticket_id.to_s, 'before') || {}
  end

  # Can still be taken back: a change (a move assigns new numbers, a delete
  # is gone), not an undo, not undone, something was changed, and inside the
  # window.
  def undoable?
    change? && !undo? && !undone? && changed_count.positive? && created_at > UNDO_WINDOW.ago
  end

  # By whom: the person who ran it, or an account admin of the organisation.
  def undoable_by?(someone)
    return false unless someone && undoable?

    (user_id.present? && someone.id == user_id) || someone.account_admin_in?(organisation)
  end
end
