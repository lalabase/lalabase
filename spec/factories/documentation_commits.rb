# frozen_string_literal: true

# == Schema Information
#
# Table name: documentation_commits
#
#  id                   :uuid             not null, primary key
#  author_name          :string
#  commit_sha           :string           not null
#  committed_at         :datetime         not null
#  message              :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  documentation_set_id :uuid             not null
#  organisation_id      :uuid             not null
#
# Indexes
#
#  idx_documentation_commits_set_sha                    (documentation_set_id,commit_sha) UNIQUE
#  idx_documentation_commits_set_time                   (documentation_set_id,committed_at)
#  index_documentation_commits_on_documentation_set_id  (documentation_set_id)
#  index_documentation_commits_on_organisation_id       (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (documentation_set_id => documentation_sets.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :documentation_commit do
    sequence(:commit_sha) { |n| Digest::SHA1.hexdigest("commit-#{n}") }
    author_name { 'Ada Lovelace' }
    message { 'docs: update setup guide' }
    committed_at { Time.current }
    documentation_set
    organisation { documentation_set.organisation }
  end
end
