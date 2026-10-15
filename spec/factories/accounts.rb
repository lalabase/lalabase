# frozen_string_literal: true

# == Schema Information
#
# Table name: accounts
#
#  id                                  :uuid             not null, primary key
#  acquisition                         :jsonb
#  billing_addressee                   :string
#  billing_city                        :string
#  billing_country                     :string(2)
#  billing_email                       :string
#  billing_email_cc                    :string
#  billing_interval                    :string           default("monthly"), not null
#  billing_name                        :string
#  billing_postal_code                 :string
#  billing_reference                   :string
#  billing_region                      :string
#  billing_starts_on                   :date
#  billing_street                      :string
#  billing_street_2                    :string
#  business_confirmation_version       :string
#  business_confirmed_at               :datetime
#  guest_max_organisations             :integer          default(1), not null
#  guest_max_projects_per_organisation :integer          default(1), not null
#  name                                :string           not null
#  payment_terms_days                  :integer          default(14), not null
#  plan_key                            :string           default("cloud"), not null
#  vat_id_checked_at                   :datetime
#  vat_id_checked_name                 :string
#  vat_id_status                       :string           default("unchecked"), not null
#  created_at                          :datetime         not null
#  updated_at                          :datetime         not null
#  business_confirmed_by_id            :uuid
#  owner_id                            :uuid
#  vat_id                              :string
#
# Indexes
#
#  index_accounts_on_billing_starts_on         (billing_starts_on)
#  index_accounts_on_business_confirmed_by_id  (business_confirmed_by_id)
#  index_accounts_on_owner_id                  (owner_id)
#
# Foreign Keys
#
#  fk_rails_...  (business_confirmed_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (owner_id => users.id) ON DELETE => nullify
#
FactoryBot.define do
  factory :account do
    sequence(:name) { |n| "Test Account #{n}" }
  end
end
