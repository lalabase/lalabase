# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Changelog', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  describe 'GET /org/:organisation_id/changelog' do
    context 'when not authenticated' do
      it 'redirects to login' do
        get organisation_changelog_path(organisation_id: organisation.id)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context 'when authenticated' do
      before do
        sign_in user
        ActsAsTenant.current_tenant = organisation
      end

      it 'returns success' do
        get organisation_changelog_path(organisation_id: organisation.id)
        expect(response).to have_http_status(:success)
      end

      it 'sets changelog_last_read_at on first visit' do
        expect(user.changelog_last_read_at).to be_nil

        get organisation_changelog_path(organisation_id: organisation.id)

        expect(user.reload.changelog_last_read_at).to be_within(2.seconds).of(Time.current)
      end

      it 'updates changelog_last_read_at on subsequent visits' do
        user.update_column(:changelog_last_read_at, 1.week.ago)

        get organisation_changelog_path(organisation_id: organisation.id)

        expect(user.reload.changelog_last_read_at).to be_within(2.seconds).of(Time.current)
      end

      # The changelog "unread" indicator lives in the sidebar account menu (not as a
      # standalone megaphone next to the logo). It is a quiet dot, cleared once the
      # changelog has been read. A single fresh entry is stubbed so "unread" depends
      # solely on the user's last-read timestamp, independent of the real md files.
      context 'unread indicator placement' do
        let(:entry) do
          Changelog::EntryLoader::Entry.new(
            slug: 'fresh', title: 'Fresh', date: Date.current,
            images: [], body: '', body_html: ''
          )
        end

        before { allow(Changelog::EntryLoader).to receive(:call).and_return([entry]) }

        it 'shows the dot in the account menu on a non-changelog page when unread' do
          user.update!(changelog_last_read_at: nil)

          get organisation_root_path(organisation_id: organisation.id)

          expect(response).to have_http_status(:success)
          expect(response.body).to include('changelog-unread-dot')
        end

        it 'hides the dot once the changelog has been read' do
          user.update!(changelog_last_read_at: Time.current)

          get organisation_root_path(organisation_id: organisation.id)

          expect(response).to have_http_status(:success)
          expect(response.body).not_to include('changelog-unread-dot')
        end

        it 'exposes the changelog entry point inside the account menu, not next to the logo' do
          get organisation_root_path(organisation_id: organisation.id)

          doc = Nokogiri::HTML(response.body)
          changelog_links = doc.css('a').select { |a| a['href']&.include?('changelog') }

          expect(changelog_links.size).to eq(1)
          expect(changelog_links.first.ancestors('details')).not_to be_empty
        end
      end
    end
  end
end
