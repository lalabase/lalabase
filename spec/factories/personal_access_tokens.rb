# frozen_string_literal: true

# == Schema Information
#
# Table name: personal_access_tokens
#
#  id                :uuid             not null, primary key
#  all_organisations :boolean          default(FALSE), not null
#  expires_at        :datetime         not null
#  last_used_at      :datetime
#  name              :string           not null
#  read_only         :boolean          default(TRUE), not null
#  revoked_at        :datetime
#  token_hash        :string           not null
#  token_prefix      :string(12)       not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  user_id           :uuid             not null
#
# Indexes
#
#  index_personal_access_tokens_on_token_hash              (token_hash) UNIQUE
#  index_personal_access_tokens_on_user_id                 (user_id)
#  index_personal_access_tokens_on_user_id_and_created_at  (user_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :personal_access_token do
    association :user
    sequence(:name) { |n| "Test Token #{n}" }
    expires_at { 30.days.from_now }

    transient do
      organisations { [] }
      project_scopes { {} } # Hash: { organisation => [projects] }
    end

    # Generates a cleartext token + scope entries BEFORE persistence,
    # so that the "must_have_at_least_one_organisation_scope" validation kicks in.
    # Convenience: factory(:personal_access_token, organisations: [org_a, org_b])
    #              creates one scope entry per org (all_projects=true unless there is a project_scope hash).
    after(:build) do |pat, evaluator|
      raw = "#{PersonalAccessToken::TOKEN_PREFIX}#{SecureRandom.alphanumeric(PersonalAccessToken::TOKEN_BODY_LENGTH)}"
      pat.token_hash = Digest::SHA256.hexdigest(raw)
      pat.token_prefix = raw.first(PersonalAccessToken::TOKEN_PREFIX_DISPLAY_LENGTH)
      pat.instance_variable_set(:@token, raw)

      evaluator.organisations.each do |org|
        pat.personal_access_token_organisations.build(
          organisation: org,
          all_projects: !evaluator.project_scopes.key?(org)
        )
      end

      evaluator.project_scopes.each_value do |projects|
        projects.each do |project|
          pat.personal_access_token_projects.build(project: project)
        end
      end
    end

    # Every organisation the owner is an active member of, now and later. No
    # organisation links: pass no `organisations:` with this trait.
    trait :all_organisations do
      all_organisations { true }
    end

    trait :revoked do
      revoked_at { Time.current }
    end

    trait :expired do
      expires_at { 1.day.ago }
    end
  end
end
