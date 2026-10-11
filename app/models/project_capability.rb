# frozen_string_literal: true

# == Schema Information
#
# Table name: project_capabilities
#
#  id                :uuid             not null, primary key
#  auto_generated    :boolean          default(TRUE), not null
#  description       :text             not null
#  key_modules       :jsonb            not null
#  name              :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  edited_by_user_id :uuid
#  organisation_id   :uuid             not null
#  project_id        :uuid             not null
#
# Indexes
#
#  index_project_capabilities_on_edited_by_user_id    (edited_by_user_id)
#  index_project_capabilities_on_organisation_id      (organisation_id)
#  index_project_capabilities_on_project_id           (project_id)
#  index_project_capabilities_on_project_id_and_name  (project_id,name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (edited_by_user_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#
class ProjectCapability < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :project
  belongs_to :edited_by_user, class_name: 'User', optional: true

  # Sidecar embeddings (embedding v2, PR 2). dependent: :delete_all fires on the
  # per-row #destroy of the Project-destroy cascade. See
  # doc/embedding_v2_pr2_sidecar_plan.md §3.5.
  has_many :content_embeddings, as: :embeddable, dependent: :delete_all

  validates :name, presence: true, uniqueness: { scope: :project_id }
  validates :description, presence: true
end
