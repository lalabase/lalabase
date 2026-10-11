# frozen_string_literal: true

require 'rails_helper'

# The ready mail must follow the user's language and link to the export PAGE —
# never to the blob: mailbox possession must not grant access to the archive.
RSpec.describe UserDataExportMailer, type: :mailer do
  describe '#ready' do
    let(:export) { create(:user_data_export, :completed, user: user) }
    let(:mail) { described_class.with(user_data_export: export).ready }

    context 'German user' do
      let(:user) { create(:user, language_preference: 'de') }

      it 'renders subject and body in German' do
        expect(mail.subject).to eq('Dein Lalabase-Datenexport ist bereit')
        expect(mail.to).to eq([user.email])
        expect(mail.body.encoded).to include('Datenexport')
      end
    end

    context 'English user' do
      let(:user) { create(:user, language_preference: 'en') }

      it 'renders subject in English' do
        expect(mail.subject).to eq('Your Lalabase data export is ready')
      end
    end

    it 'links to the export page, never to the archive blob' do
      user = create(:user)
      export = create(:user_data_export, :completed, user: user)
      body = described_class.with(user_data_export: export).ready.body.encoded

      expect(body).to include('/user_data_export')
      expect(body).not_to include('/rails/active_storage')
    end
  end
end
