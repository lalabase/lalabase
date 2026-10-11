# frozen_string_literal: true

require 'rails_helper'

# The FULL functional chain in one place — request with re-auth, background
# build, ready mail, authenticated download, real ZIP content, and finally the
# erasure interplay. Unit specs prove each part; THIS spec proves the parts
# still fit together (e.g. the job writes exactly what the download serves,
# and account deletion kills what the flow produced).
RSpec.describe 'User data export — end-to-end flow', type: :request do
  include ActiveJob::TestHelper

  let(:password) { 'password123' }
  let(:user) { create(:user, password: password, language_preference: 'de') }
  let(:organisation) { create(:organisation, name: 'Agentur Alpha') }
  let(:other_user) { create(:user) }

  before do
    ActiveJob::Base.queue_adapter = :test

    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation)
      create(:membership, user: other_user, organisation: organisation)
      create(:personal_task, user: user, organisation: organisation, title: 'Steuererklärung vorbereiten')
      create(:personal_task, user: other_user, organisation: organisation, title: 'Fremdes Geheimnis')
    end

    sign_in user
  end

  it 'runs request → job → mail → download → ZIP content → erasure purge as one chain' do
    # 1. Request (with password re-auth); drain jobs incl. the mail delivery.
    expect do
      perform_enqueued_jobs do
        post user_data_export_path, params: { current_password: password }
      end
    end.to change { ActionMailer::Base.deliveries.size }.by(1)

    export = user.user_data_exports.sole
    expect(export).to be_completed

    # 2. The ready mail reaches the right mailbox, in the user's language,
    #    linking the page — never the blob.
    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([user.email])
    expect(mail.subject).to eq('Dein Lalabase-Datenexport ist bereit')
    expect(mail.body.encoded).not_to include('/rails/active_storage')

    # 3. Download redirects to a signed blob URL and leaves an audit event.
    get download_user_data_export_path
    expect(response.location).to include('/rails/active_storage/blobs')
    expect(UserActivity.where(user: user, action: 'data_export_downloaded').count).to eq(1)

    # 4. The served archive REALLY contains the own data — and nothing foreign.
    zip = Zip::File.open_buffer(StringIO.new(export.archive.download))
    entries = zip.map(&:name)
    folder = entries.find { |e| e.start_with?('organisations/') }.split('/')[1]

    # zip entries come back as binary (ASCII-8BIT) — force UTF-8 before
    # comparing against umlaut strings.
    readme = zip.read('README.txt').force_encoding(Encoding::UTF_8)
    tasks_json = zip.read("organisations/#{folder}/personal_tasks.json").force_encoding(Encoding::UTF_8)
    all_content = zip.map { |e| e.get_input_stream.read.force_encoding(Encoding::UTF_8) }.join

    expect(readme).to include('DATENAUSKUNFT') # de locale followed the user
    expect(tasks_json).to include('Steuererklärung vorbereiten')
    expect(all_content).not_to include('Fremdes Geheimnis')

    # 5. Erasure interplay: deleting the account wipes what the flow produced.
    expect { user.soft_delete_and_anonymize! }
      .to change { UserDataExport.where(user_id: user.id).count }.from(1).to(0)
  end
end
