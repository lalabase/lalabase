# frozen_string_literal: true

require 'rails_helper'

# What: The images of a synced documentation page come from the authorized file proxy,
#       behind the same right as the page.
# Type: Request spec, in the CI guard list.
# Why:  Until this change such an image came from raw.githubusercontent.com: every reader
#       contacted GitHub, and a private repository's images did not show at all. Now the
#       instance holds a copy, and a copy of a PRIVATE repository's file must not be more
#       readable than the documentation it belongs to. The address sits in cached page
#       HTML, so it is an id without a signature: everything rests on these checks.
RSpec.describe 'Organisations::FileDownloads documentation assets', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:set) { ActsAsTenant.with_tenant(organisation) { create(:documentation_set, project: project) } }
  let(:asset) { ActsAsTenant.with_tenant(organisation) { create(:documentation_asset, documentation_set: set) } }

  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end

  let(:member) do
    create(:user).tap do |user|
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
      end
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def download(id: asset.id, headers: {})
    get organisation_file_download_path(organisation_id: organisation.id, kind: 'documentation_asset', id: id), headers: headers
  end

  def grant(access, on: project)
    create(:project_permission, user: member, project: on, documentation_access: access)
  end

  it 'serves the image to a reader of the documentation, as the type it is' do
    grant('read_only')
    sign_in member

    download

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('image/png')
    expect(response.body.b).to eq(Rails.root.join('spec/fixtures/files/test_avatar.png').binread)
  end

  it 'answers 404 to a project member without the documentation area' do
    create(:project_permission, user: member, project: project, tickets_access: 'read_write', documentation_access: 'no_access')
    sign_in member

    download

    expect(response).to have_http_status(:not_found)
  end

  it 'answers 404 for an asset of another project, to a reader of this one' do
    grant('read_only')
    other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    other_set = ActsAsTenant.with_tenant(organisation) { create(:documentation_set, project: other_project) }
    foreign = ActsAsTenant.with_tenant(organisation) { create(:documentation_asset, documentation_set: other_set) }
    sign_in member

    download(id: foreign.id)

    expect(response).to have_http_status(:not_found)
  end

  it 'answers 404 for an asset of another organisation' do
    grant('read_only')
    other_org = create(:organisation)
    foreign = ActsAsTenant.with_tenant(other_org) do
      create(:documentation_asset, documentation_set: create(:documentation_set, project: create(:project, organisation: other_org)))
    end
    sign_in member

    download(id: foreign.id)

    expect(response).to have_http_status(:not_found)
  end

  it 'sends nobody the bytes without a login' do
    download

    expect(response).to have_http_status(:redirect)
    expect(response.body).not_to include('PNG')
  end

  # One image is one request through Rails, and the general throttle counts every one
  # (rack_attack, requests/ip). The address never changes, so the browser may keep the
  # file for a short while and asks with the ETag after that.
  describe 'caching' do
    before do
      grant('read_only')
      sign_in member
    end

    it 'lets the browser keep the image privately and names its version' do
      download

      expect(response.headers['Cache-Control']).to include('private', 'max-age=')
      expect(response.headers['Cache-Control']).not_to include('public')
      expect(response.headers['ETag']).to be_present
    end

    it 'answers 304 without a body to a browser that holds this version' do
      download
      etag = response.headers['ETag']

      download(headers: { 'If-None-Match' => etag })

      expect(response).to have_http_status(:not_modified)
      expect(response.body).to be_empty
    end

    it 'sends the file again once it has changed' do
      download
      etag = response.headers['ETag']
      asset.update!(git_blob_sha: Digest::SHA1.hexdigest('another version'))

      download(headers: { 'If-None-Match' => etag })

      expect(response).to have_http_status(:ok)
    end

    it 'checks the right before it checks the version' do
      download
      etag = response.headers['ETag']
      ProjectPermission.where(user: member, project: project).update_all(documentation_access: 0)

      download(headers: { 'If-None-Match' => etag })

      expect(response).to have_http_status(:not_found)
    end
  end
end
