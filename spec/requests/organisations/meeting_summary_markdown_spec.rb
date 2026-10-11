# frozen_string_literal: true

require 'rails_helper'

# The AI summary on the meeting detail is LLM Markdown ("**Heading:**", "- item"),
# NOT plain text — it used to go through simple_format, which only turns newlines
# into <br>, so the asterisks and dashes surfaced as raw characters. It now shares
# the ONE render path (Neo::MarkdownPreviewComponent: frontmatter strip +
# Lalabase::SafeMarkdown + prose typography) with notes/transcript/analyses, so the
# four can never drift apart again.
RSpec.describe 'Organisations::Meetings summary markdown', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let(:user) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: u, organisation: organisation, role: role, active: true)
      create(:project_permission, user: u, project: project, meetings_access: 'read_only')
    end
    u
  end

  let(:summary) do
    <<~MD
      **Zusammenfassung:**
      Thema war die Aktualisierung von Tickets.
      **Offene Punkte:**
      - Klärung der *Exclude*-Funktion.
      - Korrektur des Scorings.
    MD
  end

  def meeting_with(**attrs)
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: user, **attrs)
    end
  end

  before { sign_in user }

  it 'renders the summary as HTML instead of raw markdown characters' do
    meeting = meeting_with(notes: 'Notiz.', generated_summary: summary)
    get organisation_project_meeting_path(organisation, project, meeting)

    body = response.body
    expect(body).to include('<strong>Zusammenfassung:</strong>')
    expect(body).to include('<em>Exclude</em>')
    expect(body).to include('<li>Korrektur des Scorings.</li>')
    expect(body).not_to include('**Zusammenfassung:**')
  end

  it 'typesets the summary with the shared markdown-preview scope' do
    meeting = meeting_with(notes: 'Notiz.', generated_summary: summary)
    get organisation_project_meeting_path(organisation, project, meeting)

    expect(response.body).to match(/class="[^"]*md-preview[^"]*"[^>]*>\s*<p><strong>Zusammenfassung:/)
  end
end
