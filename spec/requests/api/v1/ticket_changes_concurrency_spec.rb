# frozen_string_literal: true

require 'rails_helper'

# The response reads associations after the write commits. A move must wait
# until that whole snapshot is read, or destination data could reach a caller
# who cannot read the destination project. Use real commits and two connections.
RSpec.describe 'Ticket change response during a concurrent move', :ci_guard, type: :request do
  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end

  after { Prosopite.resume }

  it 'keeps a move from committing while the response reads the ticket associations' do
    organisation = create(:organisation)
    user = create(:user)
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation), active: true)
    project = create(:project, organisation: organisation)
    elsewhere = create(:project, organisation: organisation)
    create(:project_permission, user: user, project: project, tickets_access: :read_write)
    ticket = create(:ticket, project: project, organisation: organisation, creator: user)
    pat = build(:personal_access_token, user: user, organisations: [organisation], read_only: false)
    pat.token_hash = nil
    pat.token_prefix = nil
    pat.generate_token!
    worker = nil

    allow_any_instance_of(Tickets::Serializer).to receive(:summary).and_wrap_original do |original, record|
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          ActsAsTenant.with_tenant(organisation) do
            Ticket.transaction do
              connection.execute("SET LOCAL lock_timeout = '100ms'")
              Ticket.where(id: ticket.id).update_all(project_id: elsewhere.id, title: 'Private destination title')
            end
          end
        end
      rescue ActiveRecord::LockWaitTimeout => e
        e
      end
      expect(worker.join(10)).to be_present
      expect(worker.value).to be_a(ActiveRecord::LockWaitTimeout)
      original.call(record)
    end

    post "/api/v1/tickets/#{ticket.id}/changes", params: { change: { title: 'Renamed' } }.to_json,
                                                 headers: { 'Authorization' => "Bearer #{pat.token}", 'Content-Type' => 'application/json' }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('data', 'title')).to eq('Renamed')
    # The response has finished: the move can now acquire the same row.
    ActsAsTenant.with_tenant(organisation) do
      expect(Ticket.where(id: ticket.id).update_all(project_id: elsewhere.id)).to eq(1)
    end
  ensure
    worker&.join(2)
    worker&.kill if worker&.alive?
  end
end
