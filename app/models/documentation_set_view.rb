# frozen_string_literal: true

# Per-user "last visited" marker for a DocumentationSet, used to flag pages
# that changed since the user last looked (DT5). Disposable state.
# == Schema Information
#
# Table name: documentation_set_views
#
#  id                   :uuid             not null, primary key
#  last_viewed_at       :datetime         not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  documentation_set_id :uuid             not null
#  organisation_id      :uuid             not null
#  user_id              :uuid             not null
#
# Indexes
#
#  idx_doc_set_views_set_user                             (documentation_set_id,user_id) UNIQUE
#  index_documentation_set_views_on_documentation_set_id  (documentation_set_id)
#  index_documentation_set_views_on_organisation_id       (organisation_id)
#  index_documentation_set_views_on_user_id               (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (documentation_set_id => documentation_sets.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class DocumentationSetView < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :documentation_set
  belongs_to :user

  validates :last_viewed_at, presence: true
  validates :user_id, uniqueness: { scope: :documentation_set_id }

  # Upsert the user's visit marker to "now". Lives on the model (not the
  # controller) so the read-modify-write and its race handling are unit-testable.
  def self.record_visit!(documentation_set:, user:, organisation:)
    view = find_or_initialize_by(documentation_set: documentation_set, user: user)
    view.organisation = organisation
    view.last_viewed_at = Time.current
    view.save!
  rescue ActiveRecord::RecordNotUnique
    # Two first visits raced past find_or_initialize_by and the other request
    # inserted first. Its marker is also "now", so losing quietly is correct —
    # retrying or raising would only turn a harmless race into a 500.
  end
end
