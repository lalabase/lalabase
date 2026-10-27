# frozen_string_literal: true

require 'rails_helper'

# A participant's person link (meeting_participants.person_id) survives a save of
# the meeting form that leaves the participant alone. The form labels a member
# chip with the member's CURRENT profile name, so after a change of name the
# untouched chip comes back under another name. The actor spec covers the rule;
# this one walks the real edit form, so a change to how the form names a member
# cannot go round it.
RSpec.describe 'Meeting edit keeps the person link of a member participant', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:writer) do
    user = create(:user, first_name: 'Karl', last_name: 'Krause')
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:project_permission, user: user, project: project, meetings_access: 'read_write')
    end
    user
  end

  it 'keeps the row and person_id after the member changed their name in the profile' do
    meeting, row, person = ActsAsTenant.with_tenant(organisation) do
      m = create(:meeting, project: project, organisation: organisation, creator: writer, title: 'Retro')
      p = create(:person, organisation: organisation, name: 'Karl Krause')
      r = create(:meeting_participant, meeting: m, display_name: 'Karl Krause', user_id: writer.id)
      r.update_column(:person_id, p.id)
      [m, r, p]
    end
    writer.update!(last_name: 'Krause-Meier')
    sign_in writer

    get edit_organisation_project_meeting_path(organisation, project, meeting, format: :turbo_stream)
    expect(response).to have_http_status(:ok)
    form = Nokogiri::HTML(response.body.gsub(%r{</?template>}, ''))
    option = form.at_css(%(select#meeting-participants-select option[value="user:#{writer.id}"]))
    expect(option&.[]('selected')).to be_present

    # What the chips field posts for that chip: the option text as display_name
    # (meeting_participants_controller.js), behind the blank sentinel row.
    patch organisation_project_meeting_path(organisation, project, meeting),
          params: { meeting: { title: 'Retro', occurred_at: meeting.occurred_at,
                               participants: { '0' => { display_name: '' },
                                               '1' => { display_name: option.text.strip, user_id: writer.id } } } }
    expect(response).to have_http_status(:found)

    rows = ActsAsTenant.with_tenant(organisation) do
      MeetingParticipant.where(meeting_id: meeting.id).pluck(:id, :user_id, :person_id)
    end
    expect(rows).to eq([[row.id, writer.id, person.id]])
  end
end
