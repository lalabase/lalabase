# frozen_string_literal: true

require 'rails_helper'

# What:  A note whose text holds an @-mention, on the knowledge page and through the frame
#        road of NotesController#show (frame=content), which the knowledge page, the activity
#        page of a project and the lane of the inbox use.
# Type:  Request spec.
# Why:   Regression. ActionText hands the mention partial the attachment, not the note or
#        document, so the chip's path was nil and every page that showed a mention its reader
#        may open answered 500 ("arguments passed to url_for can't be handled"). The chip must
#        be a link for a reader of the target, on every road, and an inert label otherwise.
RSpec.describe 'Organisations::Notes show with a mention', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end
  let(:member) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: role, active: true)
    end
    u
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:target) do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, organisation: organisation, project: project, title: 'Second Note')
    end
  end
  let(:note) do
    ActsAsTenant.with_tenant(organisation) do
      create(:note, organisation: organisation, project: project, title: 'First Note',
                    content: %(<div>See <action-text-attachment sgid="#{target.attachable_sgid}"></action-text-attachment></div>))
    end
  end

  before do
    ActsAsTenant.with_tenant(organisation) { create(:project_permission, user: member, project: project, notes_access: 'read_only') }
    sign_in member
  end

  def target_path
    organisation_project_note_path(organisation, project, target)
  end

  it 'draws the chip as a link on the frame road' do
    get organisation_project_note_path(organisation, project, note, frame: 'content', frame_id: 'ticket_display_frame'),
        headers: { 'Turbo-Frame' => 'ticket_display_frame' }

    expect(response).to have_http_status(:ok)
    chip = Nokogiri::HTML(response.body).at_css('turbo-frame#ticket_display_frame a.wiki-mention')
    expect(chip).to be_present
    expect(chip['href']).to eq(target_path)
    expect(chip.text).to include('Second Note')
  end

  it 'draws the chip as a link on the frame road of the knowledge page' do
    get organisation_project_note_path(organisation, project, note, frame: 'content')

    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css('turbo-frame#knowledge_display_frame a.wiki-mention')['href'])
      .to eq(target_path)
  end

  it 'draws the chip as a link on the knowledge page itself' do
    get organisation_project_knowledge_index_path(organisation, project, note_id: note.id, type: 'all')

    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css('a.wiki-mention')['href']).to eq(target_path)
  end

  it 'draws a mention of a document as a link to the document' do
    document = ActsAsTenant.with_tenant(organisation) do
      doc = create(:document, organisation: organisation, project: project)
      version = create(:document_version, document: doc, organisation: organisation, title: 'Spec Sheet')
      doc.update!(current_version: version)
      doc
    end
    ActsAsTenant.with_tenant(organisation) do
      ProjectPermission.find_by!(user: member, project: project).update!(documents_access: 'read_only')
      note.update!(content: %(<div>See <action-text-attachment sgid="#{document.attachable_sgid}"></action-text-attachment></div>))
    end

    get organisation_project_note_path(organisation, project, note, frame: 'content', frame_id: 'ticket_display_frame')

    expect(response).to have_http_status(:ok)
    chip = Nokogiri::HTML(response.body).at_css('turbo-frame#ticket_display_frame a.wiki-mention')
    expect(chip['href']).to eq(organisation_project_document_path(organisation, project, document))
    expect(chip.at_css('i.bi-file-earmark-text')).to be_present
  end

  it 'draws an inert label on the frame road when the reader may not open the target' do
    other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    hidden = ActsAsTenant.with_tenant(organisation) do
      create(:note, organisation: organisation, project: other_project, title: 'Hidden Note')
    end
    ActsAsTenant.with_tenant(organisation) do
      note.update!(content: %(<div>See <action-text-attachment sgid="#{hidden.attachable_sgid}"></action-text-attachment></div>))
    end

    get organisation_project_note_path(organisation, project, note, frame: 'content', frame_id: 'ticket_display_frame')

    expect(response).to have_http_status(:ok)
    frame = Nokogiri::HTML(response.body).at_css('turbo-frame#ticket_display_frame')
    expect(frame.at_css('span.wiki-mention--inaccessible')).to be_present
    expect(frame.at_css('a.wiki-mention')).to be_nil
  end
end
