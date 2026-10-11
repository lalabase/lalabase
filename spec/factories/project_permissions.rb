# frozen_string_literal: true

# == Schema Information
#
# Table name: project_permissions
#
#  id                   :uuid             not null, primary key
#  chats_access         :integer          default("no_access"), not null
#  deleted_at           :datetime
#  documentation_access :integer          default("no_access"), not null
#  documents_access     :integer          default("no_access"), not null
#  last_accessed_at     :datetime
#  meetings_access      :integer          default("no_access"), not null
#  members_access       :integer          default("no_access"), not null
#  notes_access         :integer          default("no_access"), not null
#  tickets_access       :integer          default("no_access"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  project_id           :uuid             not null
#  user_id              :uuid             not null
#
# Indexes
#
#  index_project_permissions_on_deleted_at              (deleted_at)
#  index_project_permissions_on_user_id_and_project_id  (user_id,project_id) UNIQUE
#  index_project_permissions_on_user_last_accessed      (user_id,last_accessed_at)
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :project_permission do
    user
    project
    chats_access { 'no_access' }
    tickets_access { 'no_access' }
    notes_access { 'no_access' }
    documents_access { 'no_access' }
  end
end
