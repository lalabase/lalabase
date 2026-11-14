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

      # The page writes an entry's rendered Markdown through sanitize against the
      # loader's own lists (until 13.11.2026 it marked the string html_safe in the
      # view). What the renderer writes stays markup; anything else typed into an
      # entry does not reach the reader.
      context 'an entry\'s body' do
        let(:entry) do
          Changelog::EntryLoader::Entry.new(
            slug: 'markup', title: 'Markup', date: Date.current, images: [], body: '',
            body_html: '<p>Ein <strong>neuer</strong> <a href="https://example.com/x" target="_blank">Weg</a></p>' \
                       '<table><tbody><tr><td>Zelle</td></tr></tbody></table>' \
                       '<script>window.changelogProbe = 1</script><p onclick="probe()">Ende</p>'
          )
        end

        before { allow(Changelog::EntryLoader).to receive(:call).and_return([entry]) }

        it 'keeps the markup of the renderer and drops scripts and handlers' do
          get organisation_changelog_path(organisation_id: organisation.id)

          expect(response).to have_http_status(:success)
          body = Nokogiri::HTML(response.body).at_css('.prose')
          expect(body.at_css('p strong').text).to eq('neuer')
          expect(body.at_css('a[href="https://example.com/x"][target="_blank"]').text).to eq('Weg')
          expect(body.at_css('table td').text).to eq('Zelle')
          expect(body.css('script')).to be_empty
          expect(body.css('[onclick]')).to be_empty
          expect(body.text).to include('Ende')
          expect(response.body).not_to include('&lt;strong&gt;')
        end

        it 'allows every tag the real entries are rendered with' do
          allow(Changelog::EntryLoader).to receive(:call).and_call_original
          tags = Changelog::EntryLoader.call.flat_map { |loaded| Nokogiri::HTML5.fragment(loaded.body_html).css('*').map(&:name) }.uniq

          expect(tags).not_to be_empty
          expect(tags - Changelog::EntryLoader::ALLOWED_TAGS).to be_empty
        end
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

        # Off while no news are written (ApplicationHelper::CHANGELOG_IN_NAVIGATION):
        # no menu entry and no dot, even with an unread entry. The page stays reachable.
        context 'while the news are hidden from the navigation' do
          it 'shows neither the entry nor the dot' do
            user.update!(changelog_last_read_at: nil)

            get organisation_root_path(organisation_id: organisation.id)

            expect(response).to have_http_status(:success)
            expect(response.body).to include(edit_user_registration_path)
            expect(response.body).not_to include('changelog-unread-dot')
            expect(response.body).not_to include(organisation_changelog_path(organisation_id: organisation.id))
          end
        end

        context 'while the news are in the navigation' do
          before { stub_const('ApplicationHelper::CHANGELOG_IN_NAVIGATION', true) }

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

          it 'exposes the changelog entry point inside the account layer, not next to the logo' do
            get organisation_root_path(organisation_id: organisation.id)

            doc = Nokogiri::HTML(response.body)
            changelog_links = doc.css('a').select { |a| a['href']&.include?('changelog') }

            expect(changelog_links.size).to eq(1)
            expect(changelog_links.first.ancestors('#account-layer')).not_to be_empty
          end
        end
      end
    end
  end
end
