# frozen_string_literal: true

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
FactoryBot.define do
  factory :documentation_set_view do
    last_viewed_at { Time.current }
    documentation_set
    user
    organisation { documentation_set.organisation }
  end
end
