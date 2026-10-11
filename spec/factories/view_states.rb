# frozen_string_literal: true

# == Schema Information
#
# Table name: view_states
#
#  id              :uuid             not null, primary key
#  key             :string           not null
#  state           :jsonb
#  viewable_type   :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  user_id         :uuid             not null
#  viewable_id     :uuid             not null
#
# Indexes
#
#  index_view_states_on_key              (key)
#  index_view_states_on_organisation_id  (organisation_id)
#  index_view_states_on_user_id          (user_id)
#  index_view_states_on_viewable         (viewable_type,viewable_id)
#  index_view_states_unique              (user_id,key,viewable_type,viewable_id,organisation_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :view_state do
    association :user
    association :organisation
    association :viewable, factory: :organisation
    key { "test_key_#{SecureRandom.hex(4)}" }
    state { {} }

    trait :with_accordion_state do
      state do
        {
          'expanded' => true
        }
      end
    end

    trait :with_nested_state do
      state do
        {
          'accordion' => {
            'filter' => {
              'expanded' => false,
              'height' => '300px'
            }
          }
        }
      end
    end
  end
end
