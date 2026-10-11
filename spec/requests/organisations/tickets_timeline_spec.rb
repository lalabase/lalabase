# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Tickets Timeline (lazy-loaded)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:authorised_user) { create(:user) }
  let(:other_org_user) { create(:user) }

  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end

  let!(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, creator: authorised_user)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: authorised_user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation))
  end

  describe 'GET timeline' do
    context 'when authorised' do
      before { sign_in authorised_user }

      it 'returns 200 and renders the turbo-frame with timeline content' do
        get timeline_organisation_project_ticket_path(organisation, project, ticket)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(id="ticket-timeline-#{ticket.id}"))
        expect(response.body).to include('<turbo-frame')
      end
    end

    context 'when user has no access to the project' do
      let(:other_org) { create(:organisation) }
      before do
        ActsAsTenant.current_tenant = other_org
        create(:membership, user: other_org_user, organisation: other_org,
                            role: create(:admin_role, organisation: other_org))
        ActsAsTenant.current_tenant = organisation
        sign_in other_org_user
      end

      it 'does not authorise the request' do
        get timeline_organisation_project_ticket_path(organisation, project, ticket)
        # Pundit raises NotAuthorizedError → translated to redirect or 403 depending on rescue_from
        expect(response).not_to have_http_status(:ok)
      end
    end

    context 'with the header line + filter dropdown (design mock 04.09.2026)' do
      before { sign_in authorised_user }

      it 'renders the quiet header line and the switches inside the dropdown' do
        ActsAsTenant.current_tenant = organisation
        create(:post, ticket: ticket, user: authorised_user)

        get timeline_organisation_project_ticket_path(organisation, project, ticket)

        expect(response).to have_http_status(:ok)
        # The header line: "Verlauf" left, ONE word right naming what is shown.
        expect(response.body).to include('Verlauf')
        expect(response.body).to include('data-timeline-filter-target="stateWord"')
        expect(response.body).to include('data-neo-dropdown-target="menu"')
        # The switches sit one level lower but keep their wiring (targets +
        # actions unchanged); labels and counts stay visible per row.
        expect(response.body).to include('Kommentare')
        expect(response.body).to include('Änderungen')
        # The admin reads the time area, so the third row is present.
        expect(response.body).to include('Zeiteinträge')
        expect(response.body).to include('data-timeline-filter-target="postsToggleButton"')
        expect(response.body).to include('click->timeline-filter#togglePosts')
        # Default: only comments (user decision 04.09.) — exactly ONE row
        # starts pressed, and the word on the closed trigger names the state
        # server-side already.
        expect(response.body.scan('aria-pressed="true"').count).to eq(1)
        expect(response.body).to include('nur Kommentare')
        # The post itself is wrapped as a toggle target of the same controller,
        # and since T4 every day of items sits in a dayGroup with a date header.
        expect(response.body).to include('data-timeline-filter-target="post"')
        expect(response.body).to include('data-timeline-filter-target="dayGroup"')
        # Dates are values: the day header is numeric, even for today (user
        # mockup 05.09.2026).
        expect(response.body).to include(I18n.l(Date.current, format: :default, locale: :de))
        # Top-level tickets get the sub-tasks row (default off) AND the
        # section it toggles, which lives below the header row in this frame.
        expect(response.body).to include('Unteraufgaben')
        expect(response.body).to include('data-timeline-filter-target="subtasksToggleButton"')
        expect(response.body).to include('data-timeline-filter-target="subtasks"')
        # The creation renders as a change row INSIDE the timeline (the old
        # closing footer is gone, user mockup 05.09.2026).
        expect(response.body).to include('Ticket angelegt ·')
        expect(response.body).not_to include('angelegt von')
        expect(response.body).not_to include('translation_missing')
      end

      # The summary comes back from the LLM as Markdown ("### Kopf", "- Punkt",
      # "**fett**"). simple_format only turned the newlines into <br>, so the hashes
      # and asterisks stood on screen as raw characters (reported 04.09.). It now
      # goes through Neo::MarkdownPreviewComponent, the same path as the meeting
      # summary.
      context 'with a summary on the ticket' do
        let(:summary) do
          <<~MD
            ### Ausgangslage
            - **Backend**: Benutzerverwaltung, PDF-Export.
            - *Neu*: API-basierte Kundensuche.
          MD
        end

        before do
          ActsAsTenant.current_tenant = organisation
          ticket.update!(summary: summary)
        end

        it 'typesets the Markdown instead of printing its syntax' do
          get timeline_organisation_project_ticket_path(organisation, project, ticket)

          body = response.body
          expect(body).to include('<h3>Ausgangslage</h3>')
          expect(body).to include('<strong>Backend</strong>')
          expect(body).to include('<em>Neu</em>')
          expect(body).to include('<li>')
          expect(body).not_to include('### Ausgangslage')
          expect(body).not_to include('**Backend**')
        end

        it 'offers the five-line preview with a labelled toggle' do
          get timeline_organisation_project_ticket_path(organisation, project, ticket)

          body = response.body
          expect(body).to include('data-clamp-toggle-clamped-class="md-preview--clamped"')
          expect(body).to include(I18n.t('views.organisations.tickets.ticket_content_for_frame.summary_show_full'))
          expect(body).to include(I18n.t('views.organisations.tickets.ticket_content_for_frame.summary_collapse'))
        end

        # Progressive enhancement: the clamp is applied by the Stimulus controller.
        # If the SERVER ever emitted it, a reader without JavaScript would be left
        # with a cut-off summary and no way to open it.
        it 'sends the full text unclamped, with the toggle hidden' do
          get timeline_organisation_project_ticket_path(organisation, project, ticket)

          body = Nokogiri::HTML(response.body)
          content = body.at_css('[data-clamp-toggle-target="content"]')
          expect(content).to be_present
          expect(content[:class]).not_to include('md-preview--clamped')
          expect(content.text).to include('API-basierte Kundensuche')
          expect(body.at_css('[data-clamp-toggle-target="toggle"]')[:class]).to include('hidden')
        end
      end

      it 'does not offer the summary action without AI opt-in' do
        ActsAsTenant.current_tenant = organisation
        create(:post, ticket: ticket, user: authorised_user)

        get timeline_organisation_project_ticket_path(organisation, project, ticket)

        # The action moved to where its result appears (top of the timeline),
        # but ai_enabled? still gates the whole offer.
        expect(response.body).not_to include('create_summary')
      end

      it 'keeps DE and EN keys paired (fallbacks=[:de] would hide a missing EN key)' do
        %w[comments changes time_entries heading filter_label created_line].each do |key|
          %i[de en].each do |locale|
            expect(I18n.exists?("views.organisations.tickets.timeline.#{key}", locale))
              .to be(true), "missing #{locale} key: views...timeline.#{key}"
          end
        end
        %w[create_summary regenerate_summary summary_heading
           summary_show_full summary_collapse].each do |key|
          %i[de en].each do |locale|
            expect(I18n.exists?("views.organisations.tickets.ticket_content_for_frame.#{key}", locale))
              .to be(true), "missing #{locale} key: views...ticket_content_for_frame.#{key}"
          end
        end
        %w[hide_comments show_comments hide_subtasks show_subtasks
           state_all state_filtered state_only_changes state_only_comments
           state_only_time_entries].each do |key|
          %i[de en].each do |locale|
            expect(I18n.exists?("stimulus.timeline_filter.#{key}", locale))
              .to be(true), "missing #{locale} key: stimulus.timeline_filter.#{key}"
          end
        end
      end
    end
  end
end
