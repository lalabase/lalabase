# frozen_string_literal: true

# == Schema Information
#
# Table name: documentation_assets
#
#  id                   :uuid             not null, primary key
#  byte_size            :bigint           not null
#  content_type         :string           not null
#  git_blob_sha         :string           not null
#  path                 :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  documentation_set_id :uuid             not null
#  organisation_id      :uuid             not null
#
# Indexes
#
#  idx_documentation_assets_set_path              (documentation_set_id,path) UNIQUE
#  index_documentation_assets_on_organisation_id  (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (documentation_set_id => documentation_sets.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :documentation_asset do
    documentation_set
    organisation { documentation_set.organisation }
    sequence(:path) { |n| "docs/img/picture-#{n}.png" }
    git_blob_sha { Digest::SHA1.hexdigest(path) }
    content_type { 'image/png' }
    byte_size { 70 }

    after(:build) do |asset|
      next if asset.file.attached?

      asset.file.attach(
        io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
        filename: File.basename(asset.path.presence || 'image.png'),
        content_type: 'image/png'
      )
    end
  end
end
