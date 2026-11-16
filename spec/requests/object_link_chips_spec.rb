# frozen_string_literal: true

require 'rails_helper'

# What:  A link whose text is its own address of an object of this instance (ticket,
#        meeting, person, member, note, document) shows as a chip with the object's label,
#        in comments, ticket descriptions and notes (ObjectLinksHelper in the ActionText
#        layout).
# Type:  Request spec.
# Why:   The chip is the one way this feature can disclose data: it writes a title or a
#        name next to an address. It may only do so for a reader who may read the target,
#        and only for an object of the organisation the page belongs to. Everything else
#        (no right, another project, another organisation, a foreign host, a link with its
#        own wording) stays the link the author wrote.
RSpec.describe 'Object links as chips in rich text', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }
  let(:reader) { create(:user, first_name: 'Rita', last_name: 'Reader') }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, title: 'Carrier ticket') }

  let(:target) { create(:ticket, project: project, organisation: organisation, title: 'Spring release plan') }
  let(:hidden) { create(:ticket, project: other_project, organisation: organisation, title: 'Hidden budget talk') }
  let(:meeting) do
    create(:meeting, project: project, organisation: organisation, title: 'Weekly sync',
                     occurred_at: Time.zone.local(2026, 11, 12, 10))
  end
  let(:note) { create(:note, project: project, organisation: organisation, title: 'Onboarding checklist') }
  let(:document) do
    doc = create(:document, project: project, organisation: organisation)
    version = create(:document_version, document: doc, organisation: organisation, title: 'Service contract')
    doc.update!(current_version: version)
    doc
  end

  let(:host) { 'http://www.example.com' }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause do
      create(:membership, user: reader, organisation: organisation)
      create(:project_permission, user: reader, project: project, tickets_access: :read_write,
                                  meetings_access: :read_only, notes_access: :read_only, documents_access: :read_only)
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def url(path)
    "#{host}#{path}"
  end

  def link(address, text = address)
    %(<a href="#{CGI.escapeHTML(address)}">#{CGI.escapeHTML(text)}</a>)
  end

  def comment_with(*links)
    Prosopite.pause { create(:post, ticket: ticket, user: reader, content: "<div>See #{links.join(' and ')}</div>") }
  end

  def timeline_as(user)
    sign_in user
    get timeline_organisation_project_ticket_path(organisation, project, ticket)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def target_url
    url(organisation_project_ticket_path(organisation, project, target))
  end

  describe 'a readable target' do
    %i[uppercase undashed].each do |spelling|
      it "chips a working ticket address with an #{spelling} organisation UUID" do
        org_id = spelling == :uppercase ? organisation.id.upcase : organisation.id.delete('-')
        address = target_url.sub(organisation.id, org_id)
        sign_in reader
        get address
        expect(response).to have_http_status(:ok)
        comment_with(link(address))

        chip = timeline_as(reader).at_css('a.object-chip--ticket')

        expect(chip).to be_present
        expect(chip['href']).to eq(address)
        expect(chip.text).to include('Spring release plan')
      end
    end

    it 'labels the same note the knowledge page opens with repeated selection parameters' do
      path = organisation_project_knowledge_index_path(organisation, project)
      address = url("#{path}?note_id=#{note.id}&note_id=#{note.id}&document_id=#{document.id}")
      sign_in reader
      get address
      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.at_css(%(.note-content[data-note-actions-note-id-value="#{note.id}"]))).to be_present
      comment_with(link(address))

      chip = timeline_as(reader).at_css('a.object-chip')

      expect(chip).to be_present
      expect(chip['class']).to include('object-chip--note')
      expect(chip.text).to include('Onboarding checklist')
      expect(chip['href']).to eq(address)
    end

    it 'turns a ticket address into a chip that keeps the address and leaves the lane frame' do
      comment_with(link(target_url))

      chip = timeline_as(reader).at_css('a.object-chip')

      expect(chip).to be_present
      expect(chip['href']).to eq(target_url)
      expect(chip['data-turbo-frame']).to eq('_top')
      expect(chip['class']).to include('object-chip--ticket')
      expect(chip.text).to include("##{target.number} Spring release plan")
      expect(chip.at_css('i.bi[aria-hidden="true"]')).to be_present
    end

    it 'reads the lane form of an address as well' do
      address = url(organisation_meetings_path(organisation, meeting_id: meeting.id))
      comment_with(link(address))

      chip = timeline_as(reader).at_css('a.object-chip--meeting')

      expect(chip['href']).to eq(address)
      expect(chip.text).to include(I18n.l(meeting.occurred_at.to_date))
      expect(chip.text).to include('Weekly sync')
    end

    it 'names a note and a document by their titles' do
      comment_with(link(url(organisation_project_note_path(organisation, project, note))),
                   link(url(organisation_project_knowledge_index_path(organisation, project, document_id: document.id))))

      page = timeline_as(reader)

      expect(page.at_css('a.object-chip--note').text).to include('Onboarding checklist')
      expect(page.at_css('a.object-chip--document').text).to include('Service contract')
    end

    it 'cuts a long label and keeps the whole of it in the title' do
      Prosopite.pause { target.update!(title: 'A very long title that goes on and on well past forty characters') }
      comment_with(link(target_url))

      chip = timeline_as(reader).at_css('a.object-chip')
      label = chip.at_css('.object-chip__label').text

      expect(label.length).to be <= ObjectLinks::Targets::LABEL_MAX
      expect(label).to end_with('...')
      expect(chip['title']).to eq("##{target.number} A very long title that goes on and on well past forty characters")
    end

    it 'writes a title as text, never as markup' do
      Prosopite.pause { target.update!(title: '<img src=x onerror=alert(1)>') }
      comment_with(link(target_url))

      chip = timeline_as(reader).at_css('a.object-chip')

      expect(chip.at_css('img')).to be_nil
      expect(chip.text).to include('<img src=x onerror=alert(1)>')
    end
  end

  describe 'what stays the link the author wrote' do
    it 'a link with wording of its own' do
      comment_with(link(target_url, 'the plan'))

      page = timeline_as(reader)

      expect(page.at_css('a.object-chip')).to be_nil
      expect(page.at_css(%(a[href="#{target_url}"])).text).to eq('the plan')
    end

    it 'a ticket in a project the reader may not read' do
      address = url(organisation_project_ticket_path(organisation, other_project, hidden))
      comment_with(link(address))

      page = timeline_as(reader)

      expect(page.at_css(%(a[href="#{address}"])).text).to eq(address)
      expect(page.at_css('a.object-chip')).to be_nil
      expect(page.to_html).not_to include('Hidden budget talk')
    end

    it 'a ticket whose address names another project than its own' do
      address = url(organisation_project_ticket_path(organisation, other_project, target))
      comment_with(link(address))

      expect(timeline_as(reader).at_css('a.object-chip')).to be_nil
    end

    it 'an object of another organisation, under its own address and under ours' do
      foreign_org = create(:organisation)
      foreign_project = create(:project, organisation: foreign_org)
      foreign = ActsAsTenant.with_tenant(foreign_org) do
        create(:ticket, project: foreign_project, organisation: foreign_org, title: 'Foreign secret')
      end
      ActsAsTenant.current_tenant = organisation
      own_path = url(organisation_project_ticket_path(foreign_org, foreign_project, foreign))
      smuggled = url(organisation_project_ticket_path(organisation, project, foreign))
      comment_with(link(own_path), link(smuggled))

      page = timeline_as(reader)

      expect(page.at_css('a.object-chip')).to be_nil
      expect(page.to_html).not_to include('Foreign secret')
    end

    it 'an address on a foreign host' do
      address = "https://elsewhere.example.org#{organisation_project_ticket_path(organisation, project, target)}"
      comment_with(link(address))

      page = timeline_as(reader)

      expect(page.at_css('a.object-chip')).to be_nil
      expect(page.to_html).not_to include('Spring release plan')
    end

    it 'a meeting, note or document of an area the reader may not read' do
      Prosopite.pause do
        ProjectPermission.find_by!(user: reader, project: project)
                         .update!(meetings_access: :no_access, notes_access: :no_access, documents_access: :no_access)
      end
      comment_with(link(url(organisation_meetings_path(organisation, meeting_id: meeting.id))),
                   link(url(organisation_project_note_path(organisation, project, note))),
                   link(url(organisation_project_document_path(organisation, project, document))))

      page = timeline_as(reader)

      expect(page.at_css('a.object-chip')).to be_nil
      expect(page.to_html).not_to include('Weekly sync', 'Onboarding checklist', 'Service contract')
    end

    it 'a deleted target' do
      address = target_url
      Prosopite.pause { target.destroy! }
      comment_with(link(address))

      expect(timeline_as(reader).at_css('a.object-chip')).to be_nil
    end
  end

  describe 'people' do
    let(:contact) { create(:person, organisation: organisation, name: 'Doris Contact') }
    let(:colleague) { create(:user, first_name: 'Carla', last_name: 'Colleague') }

    # A member of no project the reader shares: not on the reader's members page.
    let(:stranger) { create(:user, first_name: 'Sven', last_name: 'Stranger') }

    before do
      Prosopite.pause do
        create(:membership, user: colleague, organisation: organisation)
        create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
        create(:membership, user: stranger, organisation: organisation)
        create(:project_permission, user: stranger, project: other_project, tickets_access: :read_only)
      end
    end

    def grant_people_right
      Prosopite.pause do
        role = create(:role, organisation: organisation)
        create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
        Membership.find_by!(user: reader, organisation: organisation).update!(role: role)
      end
    end

    let(:contact_address) { url(organisation_person_path(organisation, contact)) }
    let(:member_address) { url(member_organisation_people_path(organisation, user_id: colleague.id)) }

    it 'stays a link for a reader without the people right' do
      comment_with(link(contact_address), link(member_address))

      page = timeline_as(reader)

      expect(page.at_css('a.object-chip')).to be_nil
      expect(page.to_html).not_to include('Doris Contact')
    end

    it 'names a contact and a member for a reader with the right' do
      grant_people_right
      comment_with(link(contact_address), link(member_address))

      page = timeline_as(reader)

      expect(page.at_css('a.object-chip--person').text).to include('Doris Contact')
      expect(page.at_css('a.object-chip--member').text).to include('Carla Colleague')
    end

    it 'leaves a member the reader does not see on the members page a link' do
      grant_people_right
      address = url(organisation_people_path(organisation, member_id: stranger.id))
      comment_with(link(address))

      page = timeline_as(reader)

      expect(page.at_css('a.object-chip')).to be_nil
      expect(page.to_html).not_to include('Stranger')
    end

    it "spells a member's name the way the reader chose" do
      grant_people_right
      Prosopite.pause { reader.update!(preferences: { 'name_display' => 'first_last_initial' }) }
      comment_with(link(member_address))

      chip = timeline_as(reader).at_css('a.object-chip--member')

      expect(chip.text).to include('Carla C.')
      expect(chip.text).not_to include('Colleague')
    end
  end

  describe 'the three carriers' do
    it "shows the chip in a ticket's description" do
      Prosopite.pause { ticket.update!(content: "<div>#{link(target_url)}</div>") }
      sign_in reader

      get organisation_project_ticket_path(organisation, project, ticket)

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).at_css('a.object-chip--ticket').text).to include('Spring release plan')
    end

    it 'shows the chip in a note' do
      carrier = Prosopite.pause do
        create(:note, project: project, organisation: organisation, title: 'Carrier note',
                      content: "<div>#{link(target_url)}</div>")
      end
      sign_in reader

      get organisation_project_note_path(organisation, project, carrier, frame: 'content')

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).at_css('a.object-chip--ticket').text).to include('Spring release plan')
    end
  end

  describe 'without a reader' do
    it 'renders the plain link (a job, a mail, the console)' do
      post = comment_with(link(target_url))

      html = ActsAsTenant.with_tenant(organisation) { post.reload.content.to_s }

      expect(html).to include(target_url)
      expect(html).not_to include('object-chip')
      expect(html).not_to include('Spring release plan')
    end
  end
end
