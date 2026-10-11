# frozen_string_literal: true

# == Schema Information
#
# Table name: permissions
#
#  id         :uuid             not null, primary key
#  action     :string           not null
#  allowed    :boolean          default(FALSE)
#  category   :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  role_id    :uuid             not null
#
# Indexes
#
#  index_permissions_on_role_id_and_category_and_action  (role_id,category,action) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (role_id => roles.id)
#
FactoryBot.define do
  factory :permission do
    role
    category { 'projects' }
    action { 'create_new_projects' }
    allowed { true }

    # Role permissions for individual project areas
    factory :project_read_permission do
      transient do
        area { 'chats' }
      end

      category { 'projects' }
      action { "read_access_#{area}_all_projects" }
      allowed { true }
    end

    factory :project_write_permission do
      transient do
        area { 'chats' }
      end

      category { 'projects' }
      action { "write_access_#{area}_all_projects" }
      allowed { true }
    end
  end
end
