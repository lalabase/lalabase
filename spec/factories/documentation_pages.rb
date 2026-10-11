# frozen_string_literal: true

# == Schema Information
#
# Table name: documentation_pages
#
#  id                   :uuid             not null, primary key
#  git_blob_sha         :string           not null
#  markdown_body        :text
#  path                 :string           not null
#  removed_at           :datetime
#  rendered_html        :text
#  title                :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  documentation_set_id :uuid             not null
#  organisation_id      :uuid             not null
#
# Indexes
#
#  idx_documentation_pages_set_path                   (documentation_set_id,path) UNIQUE
#  idx_on_documentation_set_id_removed_at_c6f42b1828  (documentation_set_id,removed_at)
#  index_documentation_pages_on_documentation_set_id  (documentation_set_id)
#  index_documentation_pages_on_organisation_id       (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (documentation_set_id => documentation_sets.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :documentation_page do
    sequence(:path) { |n| "guide/page-#{n}.md" }
    title { 'Test Page' }
    markdown_body { '# Test Page' }
    rendered_html { '<h1>Test Page</h1>' }
    sequence(:git_blob_sha) { |n| Digest::SHA1.hexdigest("blob-#{n}") }
    documentation_set
    organisation { documentation_set.organisation }
  end
end
