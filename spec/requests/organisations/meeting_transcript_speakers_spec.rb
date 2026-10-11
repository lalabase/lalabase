# frozen_string_literal: true

require 'rails_helper'

# Wiring of Meetings::SpeakerMarkup into the meeting detail: the TRANSCRIPT gets its
# speaker turns bolded against the meeting's participants, the NOTES deliberately do
# not (they are prose, where "Problem:" / "Folge:" lines are normal).
RSpec.describe 'Organisations::Meetings transcript speakers', type: :request do
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

  def meeting_with(participants: ['Samira Barati'], **attrs)
    ActsAsTenant.with_tenant(organisation) do
      meeting = create(:meeting, project: project, organisation: organisation, creator: user, **attrs)
      participants.each do |name|
        create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: name)
      end
      meeting
    end
  end

  before { sign_in user }

  it 'bolds the transcript speaker turns of known participants' do
    meeting = meeting_with(notes: 'Notiz.', transcript: "Samira: Diese Tickets hier.\n\nGuido: Richtig.\n",
                           participants: ['Samira Barati', 'Guido Boyke'])
    get organisation_project_meeting_path(organisation, project, meeting)

    expect(response.body).to include('<strong>Samira:</strong> Diese Tickets hier.')
    expect(response.body).to include('<strong>Guido:</strong> Richtig.')
  end

  it 'leaves a transcript speaker who is not a participant unmarked' do
    meeting = meeting_with(notes: 'Notiz.', transcript: "Jürgen: Ich war auch dabei.\n",
                           participants: ['Samira Barati'])
    get organisation_project_meeting_path(organisation, project, meeting)

    expect(response.body).to include('Jürgen: Ich war auch dabei.')
    expect(response.body).not_to include('<strong>Jürgen:</strong>')
  end

  # The notes are prose: bolding every "Wort:" line there would mangle them, and the
  # participant whitelist would still hit a note that happens to start with a name.
  it 'does not apply speaker markup to the notes' do
    meeting = meeting_with(notes: "Samira: soll die Tickets schließen.\n", transcript: 'Kein Sprecher.',
                           participants: ['Samira Barati'])
    get organisation_project_meeting_path(organisation, project, meeting)

    expect(response.body).not_to include('<strong>Samira:</strong>')
  end

  # Counts the participant queries for real. Prosopite would NOT catch this: resolving
  # the speakers with an own query instead of reusing the array the header chips already
  # built is ONE extra query, not an N+1 — only a direct count holds that contract.
  # Three is the pre-existing baseline of the detail render (the list preload, the
  # header's own ordered load, and the edit-form options), measured with the speaker
  # markup removed. The point of the pin is that rendering the transcript adds NO
  # fourth: swapping the passed-in array for meeting.meeting_participants makes it 4.
  it 'adds no participant query of its own when rendering the transcript' do
    meeting = meeting_with(notes: 'Notiz.', transcript: "Samira: Eins.\nGuido: Zwei.\nBert: Drei.\n",
                           participants: ['Samira Barati', 'Guido Boyke', 'Bert Bauer'])

    queries = 0
    counter = lambda { |_n, _s, _f, _i, payload|
      queries += 1 if payload[:sql]&.include?('"meeting_participants"') && payload[:name] != 'SCHEMA'
    }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      get organisation_project_meeting_path(organisation, project, meeting)
    end

    expect(response.body).to include('<strong>Bert:</strong> Drei.')
    expect(queries).to eq(3)
  end
end
