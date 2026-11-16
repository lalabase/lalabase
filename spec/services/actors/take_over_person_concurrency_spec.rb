# frozen_string_literal: true

require 'rails_helper'

# Two takeovers of the same name into the same target, sent at once: the
# second waits for the first and then asks about its copy, instead of both
# finding no duplicate and both writing.
RSpec.describe Actors::TakeOverPerson, :ci_guard, :people_takeover do
  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  it 'lets the second takeover of a name wait and then ask about the first copy' do
    north = create(:organisation, name: 'Nord GmbH')
    south = create(:organisation, name: 'Süd GmbH')
    viewer = create(:user)
    takeover_join(viewer, north, 'view_people')
    takeover_join(viewer, south, 'manage_people')
    source = takeover_person(north, name: 'Herr Schmidt')
    arguments = { source_organisation: north, person_id: source.id, target_organisation_id: south.id,
                  fields: [], confirm_duplicate: false, current_user: viewer }
    first = described_class.new(**arguments)
    ready = Queue.new
    release = Queue.new
    allow(first).to receive(:ask_about_duplicates).and_wrap_original do |original, *args|
      ready << true
      release.pop
      original.call(*args)
    end
    worker = Thread.new { ActiveRecord::Base.connection_pool.with_connection { first.call } }
    Timeout.timeout(10) { ready.pop }

    expect do
      Person.transaction do
        Person.connection.execute("SET LOCAL lock_timeout = '100ms'")
        described_class.call(**arguments)
      end
    end.to raise_error(ActiveRecord::LockWaitTimeout)

    release << true
    expect(worker.join(10)).to be_present
    expect(worker.value).to be_success
    expect(described_class.call(**arguments).code).to eq(described_class::DUPLICATE)
    expect(takeover_count(south)).to eq(1)
  ensure
    release << true if release
    worker&.join(2)
    worker&.kill if worker&.alive?
  end
end
