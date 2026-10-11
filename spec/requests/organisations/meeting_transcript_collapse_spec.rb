# frozen_string_literal: true

require 'rails_helper'

# Transcript preview collapse on the meeting detail (Meetings-Detail kompakt). A raw
# transcript can be very long, so it is clamped to a preview by default to keep the
# detail scannable and lift the analyses/tickets below it above the fold — BUT only when
# there is other content to read first (an AI summary or notes). A transcript-only meeting
# renders expanded, otherwise the detail would open near-empty. The clamp is applied
# client-side by clamp_toggle (progressive enhancement: the server always emits the full
# text), so these specs assert the wiring is present when it should clamp and absent when
# it should not.
RSpec.describe 'Organisations::Meetings transcript collapse', type: :request do
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

  def meeting_with(**attrs)
    ActsAsTenant.with_tenant(organisation) do
      create(:meeting, project: project, organisation: organisation, creator: user, **attrs)
    end
  end

  before { sign_in user }

  it 'clamps the transcript when there are notes to read first' do
    meeting = meeting_with(notes: 'Kurze Notiz.', transcript: 'Langer Transkripttext.')
    get organisation_project_meeting_path(organisation, project, meeting)
    expect(response.body).to include('clamp-toggle')
    expect(response.body).to include('data-clamp-toggle-clamped-class="md-preview--clamped"')
    # :tall, not the default preview height — a five-line peek says nothing about
    # what is in a raw transcript.
    expect(response.body).to include('md-preview--clamp-tall')
    expect(response.body).to include(I18n.t('views.organisations.meetings.show.transcript_show_full'))
  end

  it 'renders the transcript expanded (no clamp) when it is the only content' do
    meeting = meeting_with(notes: nil, transcript: 'Langer Transkripttext.')
    get organisation_project_meeting_path(organisation, project, meeting)
    expect(response.body).to include('Langer Transkripttext.')
    expect(response.body).not_to include('clamp-toggle')
    expect(response.body).not_to include(I18n.t('views.organisations.meetings.show.transcript_show_full'))
  end
end
