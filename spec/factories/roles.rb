# frozen_string_literal: true

# == Schema Information
#
# Table name: roles
#
#  id              :uuid             not null, primary key
#  billable        :boolean          default(TRUE), not null
#  description     :text
#  is_default      :boolean          default(FALSE)
#  title           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#
# Indexes
#
#  index_roles_on_organisation_id_and_title  (organisation_id,title) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :role do
    organisation
    sequence(:title) { |n| "Role #{n}" }
    is_default { false }

    # Admin Rolle definieren
    factory :admin_role do
      title { 'account_admin' }
      description { 'Administrator mit vollen Zugriffsrechten' }
    end
  end
end
