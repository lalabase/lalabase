# frozen_string_literal: true

# == Schema Information
#
# Table name: project_indexes
#
#  id                    :uuid             not null, primary key
#  error_message         :text
#  index_version         :integer          default(1), not null
#  last_indexed_at       :datetime
#  last_indexed_commit   :string
#  layer_1_files_done    :integer          default(0), not null
#  layer_1_files_total   :integer          default(0), not null
#  layer_1_status        :string           default("pending"), not null
#  layer_3_status        :string           default("pending"), not null
#  layer_4_status        :string           default("pending"), not null
#  status                :string           default("pending"), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  project_repository_id :uuid             not null
#
# Indexes
#
#  index_project_indexes_on_organisation_id        (organisation_id)
#  index_project_indexes_on_project_repository_id  (project_repository_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_repository_id => project_repositories.id)
#
FactoryBot.define do
  # ProjectRepository.after_create_commit auto-creates a ProjectIndex via
  # enqueue_indexing!. So for any persisted project_repository there is
  # already an index in the DB. The factory adopts the auto-created index
  # (updating its attributes from the factory definition) so callers can use
  # `create(:project_index)` and get back a valid, fully-attributed record
  # without colliding with the uniqueness constraint.
  #
  # Note for explicit unique-violation tests: pass `validate: false` on
  # `save!` after `build` to bypass the adoption logic.
  factory :project_index do
    project_repository
    organisation { project_repository.organisation }
    status { 'pending' }
    layer_4_status { 'pending' }
    layer_3_status { 'pending' }
    layer_1_status { 'pending' }
    layer_1_files_total { 0 }
    layer_1_files_done { 0 }
    index_version { 1 }

    # `to_create` runs at persist time. ProjectRepository#enqueue_indexing!
    # auto-creates a ProjectIndex via after_create_commit. To stay
    # well-defined we delete that auto-created row (and clear any cached
    # inverse association) before persisting the factory-built record, so
    # the unique constraint on project_repository_id is not violated and the
    # parent repository's has_one association sees the factory record.
    to_create do |instance|
      repo = instance.project_repository
      if repo
        ProjectIndex.where(project_repository_id: repo.id).delete_all
        repo.association(:project_index).reset if repo.respond_to?(:association)
      end
      instance.save!
      repo&.association(:project_index)&.target = instance
    end
  end
end
