# frozen_string_literal: true

require 'rails_helper'

# What:  RichTextEmbedGuard does not touch the database for a save that leaves the rich
#        text alone.
# Type:  Model spec (regression, 2026-08-23, found by Paket 3's regression run).
# Why:   The first version asked `content.present?`, and `content` loads the rich text on
#        demand: a status change on twelve tickets made twelve extra queries and tripped
#        Prosopite on the onboarding banner (spec/requests/organisations/onboarding_banner_spec).
#        The guard must judge from what is in memory; an unloaded rich text cannot have
#        changed here. The second example keeps the other direction honest: a change that IS
#        in memory still reaches the guard.
RSpec.describe 'RichTextEmbedGuard queries' do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def rich_text_queries(&)
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql] if payload[:sql].include?('action_text_rich_texts')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    queries
  end

  it 'does not load the rich text when a save leaves it untouched' do
    ticket = create(:ticket, project: project, organisation: organisation, creator: user, content: '<div>Beschreibung</div>')
    fresh = Ticket.find(ticket.id)

    queries = rich_text_queries { fresh.update!(title: 'Anderer Titel') }

    expect(queries.grep(/SELECT/)).to be_empty
  end

  it 'still judges a rich text that is changed in memory' do
    ticket = create(:ticket, project: project, organisation: organisation, creator: user, content: '<div>Beschreibung</div>')
    fresh = Ticket.find(ticket.id)
    gone = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("\x89PNG\r\n\x1a\n".b), filename: 'weg.png', content_type: 'image/png')
    sgid = gone.attachable_sgid
    gone.purge
    fresh.content = %(<div>Neu</div><action-text-attachment sgid="#{sgid}"></action-text-attachment>)

    expect(fresh).not_to be_valid
    expect(fresh.errors.details[:content].map { |d| d[:error] }).to include(:embed_missing)
  end
end
