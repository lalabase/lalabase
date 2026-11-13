# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::ChangeNotificationState, 'concurrent sibling actions', type: :service do
  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end

  after { Prosopite.resume }

  it 'serializes actions on different members of the same bundle without deadlocking' do
    organisation = create(:organisation)
    user = create(:user)
    ActsAsTenant.current_tenant = organisation
    project = create(:project, organisation: organisation)
    make_token_owner_a_member(user, organisation, projects: [project])
    ticket = create(:ticket, project: project)
    rows = Array.new(2) do
      create(:notification, recipient: user, organisation: organisation, project: project,
                            notifiable: ticket, channel: 'in_app', state: :delivered)
    end
    held = Queue.new
    release = Queue.new
    second_pid = Queue.new
    allow(rows.first).to receive(:archive!).and_wrap_original do |original|
      original.call
      held << true
      release.pop
    end

    first = in_thread(organisation) do
      described_class.call(notification: rows.first, change: 'archive', current_user: user)
    end
    Timeout.timeout(10) { held.pop }
    second = in_thread(organisation) do
      second_pid << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()')
      described_class.call(notification: rows.last, change: 'archive', current_user: user)
    end
    pid = Timeout.timeout(10) { second_pid.pop }
    wait_for_lock(pid)
    release << true
    results = Timeout.timeout(10) { [first.value, second.value] }

    expect(results.grep(Exception)).to be_empty
    expect(results).to all(be_success)
    expect(rows.map { |row| row.reload.state }).to eq(%w[archived archived])
  ensure
    release&.push(true)
    [first, second].compact.each { |thread| thread.join(2) || thread.kill }
  end

  def in_thread(organisation, &block)
    Thread.new do
      Prosopite.pause
      ActiveRecord::Base.connection_pool.with_connection { ActsAsTenant.with_tenant(organisation, &block) }
    rescue ActiveRecord::Deadlocked => e
      e
    end
  end

  def wait_for_lock(pid)
    sql = ActiveRecord::Base.sanitize_sql_array(["SELECT count(*) FROM pg_stat_activity WHERE pid = ? AND wait_event_type = 'Lock'", pid])
    Timeout.timeout(10) do
      sleep 0.01 until ActiveRecord::Base.connection.select_value(sql).to_i.positive?
    end
  end
end
