# frozen_string_literal: true

require 'rails_helper'

# What: Notifications::Serializer, the inbox row shared by the HTTP API and the
#       MCP tool list_notifications.
# Type: Service spec.
# Why:  Both surfaces call it without a tenant and without a locale of their own.
#       Two guards live in .rows and are pinned here: a row is built under its
#       own organisation (a notifiable's title may load a tenanted association;
#       Document#title reads current_version), and the sentence in `message`
#       comes in the viewer's language, not in whatever locale the previous
#       request left on the thread.
RSpec.describe Notifications::Serializer do
  let(:organisation) { create(:organisation) }
  let(:viewer) { create(:user, language_preference: 'de') }
  let(:author) { create(:user) }
  let(:token) { create(:personal_access_token, user: viewer, organisations: [organisation]) }

  before { make_token_owner_a_member(viewer, organisation) }

  def inbox_rows
    Notifications::InboxQuery.call(user: viewer, reach: token.reach, status: 'all').rows
  end

  def serialized(notification)
    described_class.rows(inbox_rows, viewer: viewer).find { |r| r[:id] == notification.id }
  end

  def row(**attrs)
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, { recipient: viewer, organisation: organisation, actor: author, state: 'queued' }.merge(attrs))
    end
  end

  it 'renders the sentence the in-app inbox shows, not the event type' do
    notification = row(payload: { 'message' => 'Kaffee ist alle' }) # factory default: system_message
    expect(serialized(notification)[:message]).to eq('Systemnachricht: Kaffee ist alle')
  end

  it 'answers a nil title and no ticket block for a deleted notifiable, without crashing the page' do
    notification = row
    notification.update_columns(notifiable_id: SecureRandom.uuid)
    json = serialized(notification)
    expect(json[:notifiable]).to eq(type: 'Ticket', id: notification.notifiable_id, title: nil)
    expect(json[:ticket]).to be_nil
  end

  it 'carries the ticket block only for a ticket notifiable' do
    project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    make_token_owner_a_member(viewer, organisation, projects: [project])
    notification = row(notifiable: project, project: project,
                       event_type: Notifications::Constants::EVENT_TYPE_PROJECT_ANNOUNCEMENT)
    json = serialized(notification)
    expect(json[:ticket]).to be_nil
    expect(json[:notifiable]).to include(type: 'Project', id: project.id, title: nil)
  end

  it 'builds a row whose notifiable title loads a tenanted association, outside any tenant' do
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      # A document notification is the documents area's (Notification::AREA_BY_NOTIFIABLE_TYPE).
      make_token_owner_a_member(viewer, organisation, projects: [project], area: :documents, access: 'read_only')
      document = create(:document, project: project, organisation: organisation, creator: author)
      version = create(:document_version, document: document, organisation: organisation, title: 'Angebot v2')
      document.update!(current_version: version)
      create(:notification, recipient: viewer, organisation: organisation, actor: author, project: project,
                            notifiable: document,
                            event_type: Notifications::Constants::EVENT_TYPE_DOCUMENT_ADDED, state: 'queued')
    end
    rows = inbox_rows
    expect(ActsAsTenant.current_tenant).to be_nil

    row = described_class.rows(rows, viewer: viewer).find { |r| r[:notifiable][:type] == 'Document' }
    expect(row[:notifiable][:title]).to eq('Angebot v2')
    expect(row[:ticket]).to be_nil
  end

  it "renders message in the viewer's language, whatever locale the thread carries, and restores it" do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, :ticket_commented, recipient: viewer, organisation: organisation, actor: author,
                                               state: 'queued')
    end
    rows = inbox_rows

    german = I18n.with_locale(:en) { described_class.rows(rows, viewer: viewer).first[:message] }
    expect(german).to eq(I18n.with_locale(:de) { NotificationPresenter.new(rows.first).message })

    viewer.update!(language_preference: 'en')
    english = I18n.with_locale(:de) { described_class.rows(rows, viewer: viewer).first[:message] }
    expect(english).to eq(I18n.with_locale(:en) { NotificationPresenter.new(rows.first).message })
    expect(english).not_to eq(german)
    expect(I18n.locale).to eq(I18n.default_locale)
  end
end
