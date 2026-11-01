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
require 'rails_helper'

# What: DocumentationAsset, one image of a documentation set, copied from the repository
#       at sync time.
# Type: Model spec.
# Why:  The row is what the cached page HTML points at, by id. It has to be unique per
#       set and path (or an upsert doubles it), it has to stay inside its tenant, and
#       when it goes its file has to go with it: a documentation set that is
#       disconnected must not leave a private repository's images in the storage.
RSpec.describe DocumentationAsset, type: :model do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:set) { create(:documentation_set, project: project) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # The purge of a file is a job; the test adapter lets a block run it.
  around do |example|
    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = adapter_was
  end

  it 'is valid from its factory, with a file' do
    asset = create(:documentation_asset, documentation_set: set)

    expect(asset).to be_persisted
    expect(asset.file).to be_attached
    expect(asset.organisation).to eq(organisation)
  end

  it 'exists once per set and path' do
    create(:documentation_asset, documentation_set: set, path: 'docs/img/a.png')
    twin = build(:documentation_asset, documentation_set: set, path: 'docs/img/a.png')
    elsewhere = build(:documentation_asset, documentation_set: create(:documentation_set, project: project), path: 'docs/img/a.png')

    expect(twin).not_to be_valid
    expect(elsewhere).to be_valid
  end

  it 'needs a path, a blob SHA and a content type' do
    asset = build(:documentation_asset, documentation_set: set, path: nil, git_blob_sha: nil, content_type: nil)

    expect(asset).not_to be_valid
    expect(asset.errors.attribute_names).to include(:path, :git_blob_sha, :content_type)
  end

  it 'is invisible from another organisation' do
    asset = create(:documentation_asset, documentation_set: set)

    ActsAsTenant.with_tenant(create(:organisation)) do
      expect(described_class.find_by(id: asset.id)).to be_nil
    end
  end

  it 'takes its file along when it is destroyed' do
    asset = create(:documentation_asset, documentation_set: set)
    blob_id = asset.file.blob.id

    perform_enqueued_jobs { asset.destroy! }

    expect(ActiveStorage::Blob.find_by(id: blob_id)).to be_nil
  end

  it 'goes, file and all, when its set is destroyed' do
    asset = create(:documentation_asset, documentation_set: set)
    blob_id = asset.file.blob.id

    perform_enqueued_jobs { set.destroy! }

    expect(described_class.find_by(id: asset.id)).to be_nil
    expect(ActiveStorage::Blob.find_by(id: blob_id)).to be_nil
  end

  # The images of a customer's repository are the customer's data. Their deletion belongs
  # in the deletion register like that of any other file (AttachmentDeletionRecorder
  # works with a list of exclusions, so a new carrier is recorded unless it says otherwise).
  it 'leaves an entry in the deletion register' do
    asset = create(:documentation_asset, documentation_set: set, path: 'docs/img/aufbau.png')

    expect { perform_enqueued_jobs { asset.destroy! } }.to change(AttachmentDeletionRecord, :count).by(1)
    expect(AttachmentDeletionRecord.order(:created_at).last).to have_attributes(organisation_id: organisation.id, filename: 'aufbau.png')
  end
end
