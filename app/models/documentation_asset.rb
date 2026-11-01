# frozen_string_literal: true

# One image of a DocumentationSet, copied from the repository at sync time and served by
# the instance through the authorized file proxy.
#
# The cached HTML of a page points at this row BY ID, without a signature, so:
#   * the row is upserted per (set, path) and keeps its id when the file changes
#     (Documentation::AssetCollector);
#   * reading it is decided by the proxy, per request: DocumentationSetPolicy#show?.
#
# content_type comes from the bytes (Marcel), never from the file name: repository
# content is not ours, and a page of HTML named logo.png must not be served as one.
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
class DocumentationAsset < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :documentation_set

  has_one_attached :file

  validates :path, presence: true, uniqueness: { scope: :documentation_set_id }
  validates :git_blob_sha, presence: true
  validates :content_type, presence: true
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }
end
