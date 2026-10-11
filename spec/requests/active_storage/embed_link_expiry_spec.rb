# frozen_string_literal: true

require 'rails_helper'

# What:  The life span of an image link inside a rendered rich text, measured end to end:
#        the signed representation link (config.active_storage.urls_expire_in) and the
#        disk-service link it redirects to (ActiveStorage.service_urls_expire_in).
# Type:  Request spec (spike S3 / decision E2, 2026-08-23).
# Why:   E2 keeps signed links instead of an authorised proxy. The accepted residual risk
#        is "a copied link works for a bounded time without login, also after a revoked
#        membership". This spec pins the bound so that a config change (or a Rails
#        default change of service_urls_expire_in) cannot silently widen it. Both numbers
#        are read from the configuration, the assertions sit one minute on either side.
RSpec.describe 'Rich text embed link expiry', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  # Smallest valid PNG (1x1, transparent); the variant processor needs a real image.
  let(:png) { Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==') }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def rendered_image_path
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png), filename: 'shot.png', content_type: 'image/png')
    ticket = create(:ticket, project: project, organisation: organisation,
                             content: %(<action-text-attachment sgid="#{blob.attachable_sgid}"></action-text-attachment>))
    ActiveStorage::Current.url_options = { host: 'www.example.com' }
    html = ticket.content.to_s
    src = Nokogiri::HTML.fragment(html).at_css('img')&.[]('src')
    expect(src).to be_present
    URI.parse(src).request_uri
  end

  it 'signs representation links with the configured expiry (15 minutes) and disk links with 5' do
    expect(ActiveStorage.urls_expire_in).to eq(15.minutes)
    expect(ActiveStorage.service_urls_expire_in).to eq(5.minutes)
  end

  it 'serves the image through a redirect while both links are fresh' do
    path = rendered_image_path

    get path
    expect(response).to have_http_status(:found)
    disk_url = response.location
    expect(disk_url).to include('/rails/active_storage/disk/')

    get disk_url
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('image/png')
  end

  it 'lets the disk link die first while the representation link still renews it' do
    path = rendered_image_path
    get path
    disk_url = response.location

    travel(ActiveStorage.service_urls_expire_in + 1.minute) do
      get disk_url
      expect(response).to have_http_status(:not_found)

      get path
      expect(response).to have_http_status(:found)
      get response.location
      expect(response).to have_http_status(:ok)
    end
  end

  it 'answers 404 for the representation link after the configured expiry, without login' do
    path = rendered_image_path

    travel(ActiveStorage.urls_expire_in - 1.minute) do
      get path
      expect(response).to have_http_status(:found)
    end

    travel(ActiveStorage.urls_expire_in + 1.minute) do
      get path
      expect(response).to have_http_status(:not_found)
    end
  end

  it 'never asked for a session on the way (the residual risk E2 accepts)' do
    path = rendered_image_path
    get path
    expect(response).to have_http_status(:found)
    expect(response.location).not_to include('sign_in')
  end
end
