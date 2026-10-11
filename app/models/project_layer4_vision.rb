# frozen_string_literal: true

# == Schema Information
#
# Table name: project_layer4_visions
#
#  id                :uuid             not null, primary key
#  auto_generated    :boolean          default(TRUE), not null
#  content           :text             not null
#  language          :string           default("en"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  edited_by_user_id :uuid
#  organisation_id   :uuid             not null
#  project_id        :uuid             not null
#
# Indexes
#
#  index_project_layer4_visions_on_edited_by_user_id  (edited_by_user_id)
#  index_project_layer4_visions_on_organisation_id    (organisation_id)
#  index_project_layer4_visions_on_project_id         (project_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (edited_by_user_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#
class ProjectLayer4Vision < ApplicationRecord
  LANGUAGES = %w[de en].freeze

  acts_as_tenant(:organisation)

  belongs_to :project
  belongs_to :edited_by_user, class_name: 'User', optional: true

  # Sidecar embeddings (embedding v2, PR 2). dependent: :delete_all fires on the
  # per-row #destroy of the Project-destroy cascade. See
  # doc/embedding_v2_pr2_sidecar_plan.md §3.5.
  has_many :content_embeddings, as: :embeddable, dependent: :delete_all

  validates :content, presence: true
  validates :language, inclusion: { in: LANGUAGES }
  validates :project_id, uniqueness: true
end
