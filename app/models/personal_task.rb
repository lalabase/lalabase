# frozen_string_literal: true

# A user's private, lightweight to-do ("Notizblock") inside one organisation.
#
# Deliberately a dumb list: a one-line title + optional priority, open/done via
# completed_at. STRICTLY private to the owner — acts_as_tenant scopes to the org,
# AND every read must additionally scope to user_id (see PersonalTaskPolicy), so
# even an org admin never sees another user's tasks. No activity tracking, no
# soft delete: a hard destroy is the intended "remove".
#
#   visibility = acts_as_tenant(:organisation)  AND  where(user: current_user)
#
# Intentionally NOT wired into global search or the chat/RAG registry (both are
# fail-closed opt-in) — the to-dos must never surface there. Regression guards
# cover that we never opt in by accident.
# == Schema Information
#
# Table name: personal_tasks
#
#  id              :uuid             not null, primary key
#  completed_at    :datetime
#  position        :integer          default(0), not null
#  priority        :integer
#  title           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  user_id         :uuid             not null
#
# Indexes
#
#  index_personal_tasks_on_org_user_completed  (organisation_id,user_id,completed_at)
#  index_personal_tasks_on_user_id             (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class PersonalTask < ApplicationRecord
  acts_as_tenant :organisation

  belongs_to :user

  # Integer-backed enum; the column is nullable, so nil = "no priority" (the
  # default). Assigning an unknown value raises ArgumentError at the setter, so
  # an invalid priority can never be persisted (no separate inclusion validation
  # needed). The integer mapping is a stable contract — never renumber.
  enum :priority, { low: 0, medium: 1, high: 2 }

  # "ein Satz" — a generous single-sentence cap, not an essay field.
  TITLE_MAX_LENGTH = 500

  validates :title, presence: true, length: { maximum: TITLE_MAX_LENGTH }

  scope :open, -> { where(completed_at: nil) }
  scope :done, -> { where.not(completed_at: nil) }
  # `position` drives manual (drag) order once that lands; in the MVP it is 0
  # everywhere, so created_at DESC decides the tiebreak → newest first.
  scope :ordered, -> { order(:position, created_at: :desc) }

  def completed?
    completed_at.present?
  end

  # Flip check <-> uncheck. Kept on the model so the controller stays trivial and
  # the transition is unit-testable in isolation.
  def toggle_completed!
    update!(completed_at: completed? ? nil : Time.current)
  end
end
