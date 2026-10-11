# frozen_string_literal: true

require 'rails_helper'

# create_version error branch.
#
# Once SaveDocumentVersion stopped swallowing failures (the missing-`return`
# fix), the failure branch in DocumentsController#create_version became
# reachable for the first time. Before the controller fix that branch rendered
# a static "Fehler" label into a non-existent Turbo target (`version-form-errors`)
# and, on the HTML path, `render :show` against a template that does not exist
# (MissingTemplate -> 500).
#
# This spec pins the contract of the fixed branch: an invalid version must NOT
# be created, must NOT 500, and the real validation errors must reach the user.
RSpec.describe 'Organisations documents create_version (error branch)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end
  let(:document) { ActsAsTenant.with_tenant(organisation) { create(:document, project: project, organisation: organisation) } }

  # Turbo-aware Accept header: this is how the real version form submits
  # (form_with defaults to a Turbo stream request), so the error path under
  # test is `format.turbo_stream`, not the HTML fallback.
  let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  def member_with_write
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
      create(:project_permission, user: u, project: project, documents_access: 'read_write')
    end
    u
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # The Rack middleware resets the tenant after the request, so counting tenanted
  # models has to re-enter the tenant context.
  def version_count
    ActsAsTenant.with_tenant(organisation) { document.document_versions.count }
  end

  def upload
    Rack::Test::UploadedFile.new(StringIO.new('content'), 'text/plain', true, original_filename: 'v.txt')
  end

  it 'does not create a version when the title is blank' do
    document
    sign_in member_with_write

    expect do
      post create_version_organisation_project_document_path(organisation, project, document),
           params: { document_version: { title: '', document_version_file: upload } },
           headers: turbo_headers
    end.not_to(change { version_count })
  end

  it 'responds 422 (not 500) and surfaces the real validation error to the user' do
    document
    sign_in member_with_write

    # Locale-proof expected message: derive it from the model itself instead of
    # hard-coding a translated string.
    expected_error = ActsAsTenant.with_tenant(organisation) do
      version = document.document_versions.build(title: '')
      version.valid?
      version.errors.full_messages_for(:title).first
    end
    expect(expected_error).to be_present

    post create_version_organisation_project_document_path(organisation, project, document),
         params: { document_version: { title: '', document_version_file: upload } },
         headers: turbo_headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(expected_error)
  end

  it 'redirects instead of 500 on the non-Turbo HTML error path' do
    document
    sign_in member_with_write

    # Plain POST (no Turbo header) hits format.html, which used to `render :show`
    # against a missing template (-> 500). It must redirect with an alert instead.
    # Also guards actor.record: the redirect builds document_id from @document.id.
    post create_version_organisation_project_document_path(organisation, project, document),
         params: { document_version: { title: '', document_version_file: upload } }

    expect(response).to have_http_status(:found)
    expect(flash[:alert]).to be_present
  end

  it 'surfaces every validation error, not just the first (to_sentence)' do
    document
    sign_in member_with_write

    # Blank title AND no file -> two distinct validation errors.
    expected_errors = ActsAsTenant.with_tenant(organisation) do
      version = document.document_versions.build(title: '')
      version.valid?
      version.errors.full_messages
    end
    expect(expected_errors.size).to be >= 2

    post create_version_organisation_project_document_path(organisation, project, document),
         params: { document_version: { title: '' } },
         headers: turbo_headers

    expect(response).to have_http_status(:unprocessable_content)
    expected_errors.each { |message| expect(response.body).to include(message) }
  end

  it 'creates the version and renders a success response (200) on valid input' do
    document
    sign_in member_with_write

    expect do
      post create_version_organisation_project_document_path(organisation, project, document),
           params: { document_version: { title: 'V2', document_version_file: upload } },
           headers: turbo_headers
    end.to change { version_count }.by(1)

    # 200 distinguishes the success branch from the error branch (422); kills a
    # mutation that inverts `if result.success?`.
    expect(response).to have_http_status(:ok)
  end

  # doc/dokumentansicht_plan.md, S1: the new version gets the next number of its
  # document, one more than the highest so far, whatever the request says.
  it 'numbers the new version one above the highest of its document' do
    document
    ActsAsTenant.with_tenant(organisation) { document.document_versions.update_all(number: nil) }
    ActsAsTenant.with_tenant(organisation) do
      create(:document_version, document: document, organisation: organisation, number: 4)
    end
    sign_in member_with_write

    post create_version_organisation_project_document_path(organisation, project, document),
         params: { document_version: { title: 'V5', document_version_file: upload, number: 99 } },
         headers: turbo_headers

    newest = ActsAsTenant.with_tenant(organisation) { document.document_versions.order(:created_at).last }
    expect(newest.number).to eq(5)
  end

  # The other writer of a document's numbers, Documents::NumberVersions, holds
  # the same lock (review of #779): the next number is read under the document's
  # row lock, so a second upload, or the stock's numbering, waits for this
  # commit instead of reading the same maximum. The unique index is the last
  # line behind that, not the plan.
  it 'reads the next number under the document row lock' do
    document
    sign_in member_with_write

    statements = capture_sql do
      post create_version_organisation_project_document_path(organisation, project, document),
           params: { document_version: { title: 'V2', document_version_file: upload } },
           headers: turbo_headers
    end

    lock = statements.index { |sql| sql.match?(/FROM "documents".*FOR UPDATE/m) }
    maximum = statements.index { |sql| sql.match?(/MAX\("document_versions"\."number"\)/) }
    expect(lock).not_to be_nil
    expect(maximum).not_to be_nil
    expect(lock).to be < maximum
  end
end
