# frozen_string_literal: true

require 'rails_helper'

# Linking a meeting participant to the people directory (S2b): the chips of the
# meeting page and of the panel beside a ticket, the dialog, and its three
# writes. Rights in both directions; every negative claim about a page stands
# next to proof that the page itself was rendered.
RSpec.describe 'Organisations::MeetingParticipantLinks', :ci_guard, type: :request do
  include PeopleVisibilityHelpers

  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation, name: 'Relaunch') }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, title: 'Hosting-Abstimmung') }
  let!(:participant) { create(:meeting_participant, meeting: meeting, display_name: 'J. Weber (Hoster)') }
  let!(:contact) { create(:person, organisation: organisation, name: 'Jonas Weber', function: 'Hosting') }
  let(:pl) { 'views.organisations.meetings.participant_links' }
  # One opening of the dialog, as the form echoes it.
  let(:modal_token) { SecureRandom.hex(8) }
  let(:stream) { { 'Accept' => 'text/vnd.turbo-stream.html' } }
  let(:detail_frame) { { 'Turbo-Frame' => Organisations::MeetingsController::DETAIL_FRAME_ID } }

  def member_with(role, first_name:, active: true)
    user = create(:user, first_name: first_name, last_name: 'Beispiel')
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    User.find(user.id)
  end

  def role_with(*people_actions)
    role = create(:role, organisation: organisation)
    people_actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
    role
  end

  def admin
    @admin ||= member_with(create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE), first_name: 'Anna')
  end

  # Meetings write in the project, plus the given people rights.
  def writer(*people_actions, first_name: 'Willi')
    member_with(role_with(*people_actions), first_name: first_name).tap do |user|
      create(:project_permission, user: user, project: project, meetings_access: :read_write, tickets_access: :read_only)
    end
  end

  def show_meeting
    get organisation_project_meeting_path(organisation, project, meeting, frame: 'content'), headers: detail_frame
  end

  def link_path(target = participant, on: meeting, in_project: project)
    organisation_project_meeting_participant_link_path(organisation, in_project, on, target)
  end

  def new_link_path(target = participant)
    new_organisation_project_meeting_participant_link_path(organisation, project, meeting, target)
  end

  def post_link(choice, target: participant, on: meeting, in_project: project, **extra)
    post link_path(target, on: on, in_project: in_project),
         params: { choice: choice, modal_token: modal_token }.merge(extra), headers: stream
  end

  # The answer as a page Capybara's matchers can search: selectors instead of
  # regexes, so attribute order and quoting do not matter.
  def page_markup
    Capybara.string(response.body)
  end

  # The markup one stream of the answer carries. A stream's markup is the content
  # of its <template>, which Capybara's HTML5 parser keeps out of the tree it
  # searches; a missing stream fails here instead of turning a negative check green.
  def stream_markup(action, target)
    node = Nokogiri::HTML(response.body).at_css(%(turbo-stream[action="#{action}"][target="#{target}"]))
    raise "no #{action} stream for #{target} in the answer" unless node

    Capybara.string(node.at_css('template').inner_html)
  end

  def dialog_instance_id
    "meeting-participant-link-modal-#{meeting.id}-#{modal_token}"
  end

  def chips_id
    ActionView::RecordIdentifier.dom_id(meeting, :participants)
  end

  describe 'the participant row' do
    it 'offers the link action to a writer with view_people' do
      sign_in writer('view_people')
      show_meeting

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('J. Weber (Hoster)')
      expect(response.body).to include(CGI.escapeHTML(new_link_path))
      expect(response.body).to include(I18n.t("#{pl}.link", name: 'J. Weber (Hoster)'))
    end

    it 'offers nothing without view_people, and links no chip' do
      participant.update!(person: contact)
      sign_in writer
      show_meeting

      expect(response.body).to include('J. Weber (Hoster)')
      expect(response.body).not_to include(new_link_path)
      expect(response.body).not_to include(organisation_people_path(organisation, person_id: contact.id))
    end

    it 'offers nothing to a reader of the meeting, but links the chip' do
      participant.update!(person: contact)
      reader = member_with(role_with('view_people'), first_name: 'Rita')
      create(:project_permission, user: reader, project: project, meetings_access: :read_only)
      sign_in reader
      show_meeting

      expect(response.body).to include('J. Weber (Hoster)')
      expect(response.body).not_to include(new_link_path)
      expect(response.body).to include(CGI.escapeHTML(organisation_people_path(organisation, person_id: contact.id)))
    end

    it 'links a member chip to the member, with or without a row, and offers no link for it' do
      colleague = member_with(create(:role, organisation: organisation), first_name: 'Carl')
      member_participant = create(:meeting_participant, meeting: meeting, display_name: 'Carl Beispiel', user: colleague)
      sign_in admin
      show_meeting

      expect(response.body).to include(CGI.escapeHTML(organisation_people_path(organisation, member_id: colleague.id)))
      expect(response.body).not_to include(new_link_path(member_participant))

      row = create(:person, organisation: organisation, name: 'Carl Beispiel', user: colleague)
      show_meeting
      expect(response.body).to include(CGI.escapeHTML(organisation_people_path(organisation, person_id: row.id)))
    end

    it 'links the chip of a former member to the row that keeps their meetings' do
      former = member_with(create(:role, organisation: organisation), first_name: 'Fritz')
      row = create(:person, organisation: organisation, name: 'Fritz Beispiel', user: former)
      Membership.where(user: former, organisation: organisation).update_all(active: false)
      create(:meeting_participant, meeting: meeting, display_name: 'Fritz Beispiel', user: former)
      sign_in admin
      show_meeting

      expect(response.body).to include(CGI.escapeHTML(organisation_people_path(organisation, person_id: row.id)))
    end

    # A member who left the organisation: their row lost its account
    # (PersonLinkRelease), the participant still carries it. The name is a
    # contact again and can be linked to that row, which then lists the meeting.
    it 'lets the participant of a removed member be linked as a contact' do
      gone = member_with(create(:role, organisation: organisation), first_name: 'Gerd')
      row = create(:person, organisation: organisation, name: 'Gerd Beispiel', user: gone)
      gone_participant = create(:meeting_participant, meeting: meeting, display_name: 'Gerd Beispiel', user: gone)
      # Still a member elsewhere: only the membership HERE counts.
      elsewhere = create(:organisation)
      ActsAsTenant.with_tenant(elsewhere) do
        create(:membership, user: gone, organisation: elsewhere, role: create(:role, organisation: elsewhere), active: true)
      end
      RemoveMembershipService.new(membership: gone.memberships.find_by!(organisation: organisation), admin: admin).call
      expect(row.reload.user_id).to be_nil
      sign_in admin

      show_meeting
      expect(response.body).to include(CGI.escapeHTML(new_link_path(gone_participant)))

      post_link("person:#{row.id}", target: gone_participant)
      expect(response).to have_http_status(:ok)
      expect(gone_participant.reload.slice(:person_id, :user_id)).to eq('person_id' => row.id, 'user_id' => nil)

      get organisation_people_path(organisation, person_id: row.id), headers: { 'Turbo-Frame' => Organisations::PeopleController::DETAIL_FRAME_ID }
      expect(response.body).to include('Hosting-Abstimmung')
    end

    it 'offers no link for the participant of a deactivated member' do
      dora = member_with(create(:role, organisation: organisation), first_name: 'Dora')
      dora_participant = create(:meeting_participant, meeting: meeting, display_name: 'Dora Beispiel', user: dora)
      Membership.where(user: dora, organisation: organisation).update_all(active: false)
      sign_in admin
      show_meeting

      expect(response.body).to include('Dora Beispiel', CGI.escapeHTML(new_link_path))
      expect(response.body).not_to include(new_link_path(dora_participant))
    end

    it 'keeps a chip as text when its person is a row the viewer may not see' do
      hidden_row = row_out_of_sight(organisation: organisation, name: 'Hanna Beispiel')
      participant.update!(person: hidden_row)
      viewer = writer('view_people')
      sign_in viewer
      show_meeting

      expect(response.body).to include('J. Weber (Hoster)')
      expect(response.body).not_to include(organisation_people_path(organisation, person_id: hidden_row.id))
      expect(response.body).not_to include('Hanna Beispiel')
    end

    it 'renders the row of several participants in a fixed number of queries' do
      Prosopite.pause do
        3.times { |i| create(:meeting_participant, meeting: meeting, display_name: "Gast #{i}", person: create(:person, organisation: organisation)) }
      end
      sign_in admin

      show_meeting

      expect(response).to have_http_status(:ok)
    end

    it 'offers to change a link, from a single trigger the focus can come back to' do
      participant.update!(person: contact)
      sign_in admin
      show_meeting

      label = I18n.t("#{pl}.change", name: 'J. Weber (Hoster)')
      expect(page_markup).to have_css(%(a[title="#{label}"] i.bi-pencil), visible: :all)
      expect(page_markup).to have_css("[id='meeting-participant-link-trigger-#{participant.id}']", count: 1)
    end

    # The row was linked to a member after the participant was linked to it: the
    # participant is that member now, and the meeting form owns its link.
    it 'offers no link action for a contact whose row belongs to a member now' do
      participant.update!(person: contact)
      contact.update!(user: member_with(create(:role, organisation: organisation), first_name: 'Jonas'))
      sign_in admin
      show_meeting

      expect(response.body).to include('J. Weber (Hoster)',
                                       CGI.escapeHTML(organisation_people_path(organisation, person_id: contact.id)))
      expect(response.body).not_to include(new_link_path)
    end

    it 'shows the links in the panel beside a ticket too' do
      ticket = create(:ticket, project: project, organisation: organisation, title: 'Ticket mit Meeting')
      meeting.outgoing_references.create!(organisation: organisation, target: ticket, target_title_snapshot: ticket.display_title)
      participant.update!(person: contact)
      sign_in admin

      get organisation_project_ticket_meeting_panel_path(organisation, project, ticket, meeting_id: meeting.id),
          headers: { 'Turbo-Frame' => 'ticket_meeting_panel' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('J. Weber (Hoster)')
      expect(response.body).to include(CGI.escapeHTML(organisation_people_path(organisation, person_id: contact.id)))
      expect(response.body).to include(CGI.escapeHTML(new_link_path))
    end
  end

  describe 'the dialog' do
    it 'names the participant, suggests the same surname first and offers a new person' do
      create(:person, organisation: organisation, name: 'Anton Anders')
      sign_in admin

      get new_link_path, headers: { 'Turbo-Frame' => "meeting-participant-link-modal-#{meeting.id}" }

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include(CGI.escapeHTML(I18n.t("#{pl}.participant", name: 'J. Weber (Hoster)')))
      expect(body.index('Jonas Weber')).to be < body.index('Anton Anders')
      expect(body).to include(I18n.t("#{pl}.suggestion"))
      expect(body).to include(I18n.t("#{pl}.new_person"), 'value="J. Weber"')
      expect(page_markup).to have_css('input[name=choice]', visible: :all)
      expect(page_markup).to have_no_css('input[name=choice][checked]', visible: :all)
      expect(page_markup).to have_css("input[value='person:#{contact.id}']", count: 1, visible: :all)
    end

    it 'searches in its list frame' do
      create(:person, organisation: organisation, name: 'Anton Anders')
      sign_in admin

      get new_link_path, params: { q: 'anders' }, headers: { 'Turbo-Frame' => "meeting-participant-link-results-#{participant.id}" }

      expect(response.body).to include('Anton Anders')
      expect(response.body).not_to include('Jonas Weber')
      expect(response.body).not_to include(I18n.t("#{pl}.suggestion"))
      # Only the list frame, not the whole dialog around it.
      expect(response.body).to include("id=\"meeting-participant-link-results-#{participant.id}\"")
      expect(response.body).not_to include(I18n.t("#{pl}.title"), "meeting-participant-link-modal-#{meeting.id}")
    end

    it 'shows the line under a name: function of a row, email of a member' do
      colleague = member_with(create(:role, organisation: organisation), first_name: 'Carl')
      sign_in admin

      get new_link_path

      expect(response.body).to include('Jonas Weber', 'Hosting', 'Carl Beispiel', CGI.escapeHTML(colleague.email))
    end

    it 'does not name a linked person the viewer may not see' do
      hidden_row = row_out_of_sight(organisation: organisation, name: 'Hanna Weber')
      participant.update_column(:person_id, hidden_row.id)
      sign_in writer('view_people')

      get new_link_path

      expect(response.body).to include(I18n.t("#{pl}.linked"), 'Jonas Weber')
      expect(response.body).not_to include('Hanna Weber')
    end

    it 'names the visible person the participant is linked to' do
      participant.update!(person: contact)
      sign_in admin

      get new_link_path

      expect(response.body).to include(CGI.escapeHTML(I18n.t("#{pl}.linked_to", name: 'Jonas Weber')))
    end

    it 'offers no new person without manage_people' do
      sign_in writer('view_people')

      get new_link_path

      expect(response.body).to include('Jonas Weber')
      expect(response.body).not_to include(I18n.t("#{pl}.new_person"))
    end

    it 'lists no person of another organisation and no row of an invisible member' do
      ActsAsTenant.with_tenant(create(:organisation)) { create(:person, name: 'Fremde Weber') }
      row_out_of_sight(organisation: organisation, name: 'Hanna Weber')
      sign_in writer('view_people')

      get new_link_path

      expect(response.body).to include('Jonas Weber')
      expect(response.body).not_to include('Fremde Weber')
      expect(response.body).not_to include('Hanna Weber')
    end
  end

  describe 'linking' do
    it 'links a contact: the row becomes a link, and the person lists the meeting' do
      sign_in admin

      post_link("person:#{contact.id}")

      expect(response).to have_http_status(:ok)
      expect(participant.reload.person_id).to eq(contact.id)
      expect(response.body).to include("turbo-stream action=\"replace\" target=\"#{chips_id}\"")
      expect(response.body).to include("action=\"remove\" target=\"meeting-participant-link-modal-#{meeting.id}-#{modal_token}\"")
      expect(response.body).to include(CGI.escapeHTML(organisation_people_path(organisation, person_id: contact.id)))

      get organisation_people_path(organisation, person_id: contact.id), headers: { 'Turbo-Frame' => Organisations::PeopleController::DETAIL_FRAME_ID }
      expect(response.body).to include('Hosting-Abstimmung')
    end

    it 'redraws the chips without the dialog frame, so a late answer closes no other dialog' do
      sign_in admin

      post_link("person:#{contact.id}")

      replaced = stream_markup('replace', chips_id)
      expect(replaced).to have_text('J. Weber (Hoster)')
      expect(replaced).to have_no_css("turbo-frame[id='meeting-participant-link-modal-#{meeting.id}']", visible: :all)
    end

    it 'links a member by account and leaves person_id empty' do
      colleague = member_with(create(:role, organisation: organisation), first_name: 'Carl')
      sign_in admin

      post_link("member:#{colleague.id}")

      expect(participant.reload.user_id).to eq(colleague.id)
      expect(participant.person_id).to be_nil
    end

    it 'refuses a member already in the meeting with the dialog and a reason' do
      colleague = member_with(create(:role, organisation: organisation), first_name: 'Carl')
      create(:meeting_participant, meeting: meeting, display_name: 'Carl Beispiel', user: colleague)
      # A list of suggestions only: the pick is no suggestion and must still be there.
      stub_const('Organisations::MeetingParticipantLinksController::LIST_LIMIT', 0)
      sign_in admin

      post_link("member:#{colleague.id}")

      expect(response).to have_http_status(:unprocessable_content)
      # The pick stays marked, also when it is not among the first lines of the list.
      expect(stream_markup('replace', dialog_instance_id))
        .to have_css("input[value='member:#{colleague.id}'][checked]", visible: :all)
      expect(response.body).to include(I18n.t('services.actors.link_meeting_participant.member_already_participant'))
      expect(participant.reload.user_id).to be_nil
    end

    # The pick of a refused save is put back into the list; it must not stand twice,
    # whether the dialog lists it as a suggestion or among the others.
    it 'lists a refused pick once, as a suggestion or among the others' do
      suggested = create(:user, first_name: 'Karl', last_name: 'Weber')
      listed = member_with(create(:role, organisation: organisation), first_name: 'Carl')
      create(:membership, user: suggested, organisation: organisation, role: create(:role, organisation: organisation), active: true)
      create(:meeting_participant, meeting: meeting, display_name: 'Karl Weber', user: suggested)
      create(:meeting_participant, meeting: meeting, display_name: 'Carl Beispiel', user: listed)
      sign_in admin

      [suggested, listed].each do |pick|
        post_link("member:#{pick.id}")

        expect(response).to have_http_status(:unprocessable_content)
        expect(stream_markup('replace', dialog_instance_id))
          .to have_css("input[value='member:#{pick.id}']", count: 1, visible: :all)
      end
      expect(response.body).to include(I18n.t("#{pl}.suggestion"))
    end

    it 'refuses without a choice' do
      sign_in admin

      post_link('')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('services.actors.link_meeting_participant.nothing_picked'))
    end

    it 'answers our own failure with a 500 and the dialog' do
      failure = Actors::BaseActor::Result.new(success: false, errors: ['Interner Fehler'], code: :internal_error)
      allow(Actors::LinkMeetingParticipant).to receive(:call).and_return(failure)
      sign_in admin

      post_link("person:#{contact.id}")

      expect(response).to have_http_status(:internal_server_error)
      expect(response.body).to include("action=\"replace\" target=\"meeting-participant-link-modal-#{meeting.id}-#{modal_token}\"",
                                       'Interner Fehler')
    end

    # The token names one opening of the dialog in a stream target: only 16 hex
    # characters count, anything else answers as if there were no dialog.
    { 'a leading character' => '-0123456789abcdef', 'a trailing character' => '0123456789abcdef-',
      'one character short' => '0123456789abcde', 'no hex at all' => 'not-a-token' }.each do |label, bad|
      it "uses no token with #{label}" do
        sign_in admin

        post_link('', modal_token: bad)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("action=\"replace\" target=\"#{chips_id}\"",
                                         I18n.t('services.actors.link_meeting_participant.nothing_picked'))
        expect(response.body).not_to include('target="meeting-participant-link-modal-')
      end
    end

    it 'removes no dialog after a link without a token' do
      sign_in admin

      post_link("person:#{contact.id}", modal_token: '')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("action=\"replace\" target=\"#{chips_id}\"")
      expect(response.body).not_to include('action="remove"')
    end

    it 'creates a person and links it' do
      sign_in writer('manage_people')

      expect { post_link('new', new_person_name: 'J. Weber') }.to change(Person, :count).by(1)
      expect(participant.reload.person.name).to eq('J. Weber')
    end

    it 'keeps the new person picked and the typed name after a refusal' do
      sign_in writer('manage_people')

      post_link('new', new_person_name: ' ')

      expect(response).to have_http_status(:unprocessable_content)
      dialog = stream_markup('replace', dialog_instance_id)
      expect(dialog).to have_css('input[name=choice][value=new][checked]', visible: :all)
      expect(dialog).to have_field('new_person_name', with: ' ')
    end

    it 'creates no person without manage_people' do
      sign_in writer('view_people')

      expect { post_link('new', new_person_name: 'J. Weber') }.not_to change(Person, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(participant.reload.person_id).to be_nil
    end

    it 'unlinks' do
      participant.update!(person: contact)
      sign_in writer('view_people')

      delete link_path, params: { modal_token: modal_token }, headers: stream

      expect(response).to have_http_status(:ok)
      expect(participant.reload.person_id).to be_nil
      expect(response.body).to include(I18n.t('flash.meeting_participant_links.unlinked'))
    end
  end

  describe 'who may not link' do
    def expect_unchanged
      expect(participant.reload.person_id).to be_nil
      expect(participant.user_id).to be_nil
    end

    it 'refuses a writer without view_people, also the dialog' do
      sign_in writer

      post_link("person:#{contact.id}")
      expect(response).to have_http_status(:found)
      get new_link_path
      expect(response).to have_http_status(:found)
      expect(response.body).not_to include(I18n.t("#{pl}.title"))
      expect_unchanged
    end

    it 'refuses a reader of the meeting with view_people' do
      reader = member_with(role_with('manage_people'), first_name: 'Rita')
      create(:project_permission, user: reader, project: project, meetings_access: :read_only)
      sign_in reader

      post_link("person:#{contact.id}")
      expect(response).to have_http_status(:found)
      get new_link_path
      expect(response).to have_http_status(:found)
      expect_unchanged
    end

    # Unlinking reads nothing of the directory, so only the controller's checks hold it.
    it 'refuses to unlink for a writer without view_people' do
      participant.update!(person: contact)
      sign_in writer

      delete link_path, params: { modal_token: modal_token }, headers: stream

      expect(response).to have_http_status(:found)
      expect(participant.reload.person_id).to eq(contact.id)
    end

    it 'refuses to unlink for a reader of the meeting with view_people' do
      participant.update!(person: contact)
      reader = member_with(role_with('manage_people'), first_name: 'Rita')
      create(:project_permission, user: reader, project: project, meetings_access: :read_only)
      sign_in reader

      delete link_path, params: { modal_token: modal_token }, headers: stream

      expect(response).to have_http_status(:found)
      expect(participant.reload.person_id).to eq(contact.id)
    end

    it 'refuses a member of another organisation' do
      stranger_org = create(:organisation)
      stranger = ActsAsTenant.with_tenant(stranger_org) do
        user = create(:user)
        create(:membership, user: user, organisation: stranger_org,
                            role: create(:role, organisation: stranger_org, title: Role::ACCOUNT_ADMIN_TITLE), active: true)
        user
      end
      sign_in stranger

      post_link("person:#{contact.id}")

      expect(response.status).to be_in([302, 404])
      expect_unchanged
    end

    it 'does not find a person of another organisation' do
      foreign = ActsAsTenant.with_tenant(create(:organisation)) { create(:person, name: 'Fremde Weber') }
      sign_in admin

      post_link("person:#{foreign.id}")

      expect(response).to have_http_status(:not_found)
      # The dialog is drawn again for the pick, and still names nobody it may not see.
      expect(response.body).to include(I18n.t('services.actors.link_meeting_participant.not_found'))
      expect(response.body).not_to include('Fremde Weber')
      expect_unchanged
    end

    it 'does not find the row of a member the writer may not see' do
      hidden_row = row_out_of_sight(organisation: organisation, name: 'Hanna Weber')
      sign_in writer('view_people')

      post_link("person:#{hidden_row.id}")
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include(I18n.t('services.actors.link_meeting_participant.not_found'))
      expect(response.body).not_to include('Hanna Weber')
      post_link("member:#{hidden_row.user_id}")
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('Hanna Weber')
      expect_unchanged
    end

    it 'does not find a participant of another meeting' do
      other_meeting = create(:meeting, organisation: organisation, project: project)
      other = create(:meeting_participant, meeting: other_meeting, display_name: 'Jonas Weber')
      sign_in admin

      post link_path(other), params: { choice: "person:#{contact.id}" }, headers: stream

      expect(response).to have_http_status(:not_found)
      expect(other.reload.person_id).to be_nil
    end

    # A move that commits between the lookup and the lock (lock_in_project! reloads the
    # meeting): the answer closes the dialog and draws nothing of the new project.
    it 'answers a meeting moved during the request without drawing it again' do
      target = create(:project, organisation: organisation)
      allow_any_instance_of(Meeting).to receive(:lock_in_project!) do |moved, _project_id|
        moved.update_columns(project_id: target.id)
        false
      end
      sign_in admin

      post_link("person:#{contact.id}")

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("action=\"remove\" target=\"meeting-participant-link-modal-#{meeting.id}-#{modal_token}\"")
      expect(response.body).not_to include(target.id, 'action="replace"')
    end

    it 'does not find a meeting moved into another project' do
      target = create(:project, organisation: organisation)
      Actors::MoveMeeting.call(meeting: meeting, target_project: target, current_user: admin)
      expect(meeting.reload.project_id).to eq(target.id)
      sign_in admin

      post_link("person:#{contact.id}")

      expect(response).to have_http_status(:not_found)
      expect_unchanged
    end
  end

  # A dialog or a panel left open while the meeting moved to another project: its
  # next request finds nothing here. It says so where the dialog would be, instead
  # of Turbo's "Content missing", and draws nothing of the meeting.
  describe 'a meeting moved while its row was open' do
    before do
      meeting.update_columns(project_id: create(:project, organisation: organisation).id)
      sign_in admin
    end

    let(:reason) { I18n.t('services.actors.link_meeting_participant.not_found') }

    it 'answers the dialog frame with the reason' do
      get new_link_path, headers: { 'Turbo-Frame' => "meeting-participant-link-modal-#{meeting.id}" }

      expect(response).to have_http_status(:not_found)
      expect(page_markup).to have_css("turbo-frame[id='meeting-participant-link-modal-#{meeting.id}']", text: reason)
    end

    it 'closes the dialog with the reason after a link' do
      post_link("person:#{contact.id}")

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include(%(turbo-stream action="remove" target="#{dialog_instance_id}"), reason)
      expect(response.body).not_to include('action="replace"')
      expect(participant.reload.person_id).to be_nil
    end
  end

  # The dialog always posts as a stream; a form without Turbo still gets an answer.
  describe 'without Turbo (a plain form submit)' do
    before { sign_in admin }

    it 'goes back to the meeting with a notice after a link' do
      post link_path, params: { choice: "person:#{contact.id}" }

      expect(response).to redirect_to(organisation_project_meetings_path(organisation, project, meeting_id: meeting.id))
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq(I18n.t('flash.meeting_participant_links.linked'))
    end

    it 'goes back to the meeting with the reason after a refusal' do
      post link_path, params: { choice: '' }

      expect(response).to redirect_to(organisation_project_meetings_path(organisation, project, meeting_id: meeting.id))
      expect(flash[:alert]).to eq(I18n.t('services.actors.link_meeting_participant.nothing_picked'))
    end

    it 'goes back to the meetings of the project when someone is out of reach' do
      foreign = ActsAsTenant.with_tenant(create(:organisation)) { create(:person, name: 'Fremde Weber') }

      post link_path, params: { choice: "person:#{foreign.id}" }

      expect(response).to redirect_to(organisation_project_meetings_path(organisation, project))
      expect(flash[:alert]).to eq(I18n.t('services.actors.link_meeting_participant.not_found'))
    end
  end

  describe 'a later edit of the meeting' do
    def edit_with(display_name:, user_id: nil)
      patch organisation_project_meeting_path(organisation, project, meeting, format: :turbo_stream),
            params: { meeting: { title: meeting.title, participants: [{ display_name: display_name, user_id: user_id.to_s }] },
                      frame_id: Organisations::MeetingsController::DETAIL_FRAME_ID }
    end

    it 'keeps a contact link when the name stays' do
      sign_in admin
      post_link("person:#{contact.id}")

      edit_with(display_name: 'J. Weber (Hoster)')

      expect(response).to have_http_status(:ok)
      expect(participant.reload.person_id).to eq(contact.id)
    end

    it 'keeps one key when the form makes a contact-linked row a member' do
      colleague = member_with(create(:role, organisation: organisation), first_name: 'Carl')
      sign_in admin
      post_link("person:#{contact.id}")

      edit_with(display_name: 'J. Weber (Hoster)', user_id: colleague.id)

      expect(participant.reload.user_id).to eq(colleague.id)
      expect(participant.person_id).to be_nil
    end

    # The form labels a member chip with the member's profile name, so the row is kept by
    # its member, not by its name (SaveMeeting#match_participant_rows).
    it 'keeps a member link, which the form sends as user_id under the profile name' do
      colleague = member_with(create(:role, organisation: organisation), first_name: 'Carl')
      create(:project_permission, user: colleague, project: project, meetings_access: :read_only)
      sign_in admin
      post_link("member:#{colleague.id}")

      edit_with(display_name: colleague.display_name, user_id: colleague.id)

      expect(response).to have_http_status(:ok)
      expect(participant.reload.user_id).to eq(colleague.id)
      expect(meeting.meeting_participants.count).to eq(1)
    end
  end
end
