# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Concurrent saved view updates' do
  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end
  after { Prosopite.resume }

  it 'serializes replacement of an empty rule tree instead of combining both saves' do
    organisation = create(:organisation)
    ActsAsTenant.current_tenant = organisation
    user = create(:user)
    project = create(:project, organisation: organisation)
    folder = create(:smart_folder, user: user, organisation: organisation, project: project, target_object_type: 'Meeting')
    arguments = { project: project, current_user: user, operator_params: {}, name: folder.name }
    first = Actors::SaveSmartFolderFromFilters.new(**arguments, smart_folder: folder, filter_params: { 'participant' => ['Anna'] })
    ready = Queue.new
    release = Queue.new
    allow(first).to receive(:persist_rules).and_wrap_original do |original, conversion|
      ready << true
      release.pop
      original.call(conversion)
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActsAsTenant.with_tenant(organisation) { first.call }
      end
    end
    Timeout.timeout(10) { ready.pop }
    expect do
      SmartFolder.transaction do
        SmartFolder.connection.execute("SET LOCAL lock_timeout = '100ms'")
        Actors::SaveSmartFolderFromFilters.call(**arguments, smart_folder: SmartFolder.find(folder.id), filter_params: { 'participant' => ['Bert'] })
      end
    end.to raise_error(ActiveRecord::LockWaitTimeout)
    release << true
    expect(worker.join(10)).to be_present
    expect(worker.value).to be_success

    second = Actors::SaveSmartFolderFromFilters.call(**arguments, smart_folder: folder.reload, filter_params: { 'participant' => ['Bert'] })
    expect(second).to be_success
    expect(folder.reload.smart_folder_rule_groups.size).to eq(1)
    expect(JSON.parse(folder.smart_folder_rules.sole.value)).to eq(['Bert'])
  ensure
    release << true if release
    worker&.join(2)
    worker&.kill if worker&.alive?
  end

  def in_thread(organisation, &block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { ActsAsTenant.with_tenant(organisation, &block) }
    end
  end

  def wait_for_lock_waiter
    Timeout.timeout(10) do
      sleep 0.02 until ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database()"
      ).to_i.positive?
    end
  end

  it 'lets the later of two concurrent replacements win completely' do
    organisation = create(:organisation)
    ActsAsTenant.current_tenant = organisation
    user = create(:user)
    project = create(:project, organisation: organisation)
    folder = create(:smart_folder, user: user, organisation: organisation, project: project, target_object_type: 'Meeting')
    arguments = { project: project, current_user: user, operator_params: {}, name: folder.name }
    first = Actors::SaveSmartFolderFromFilters.new(**arguments, smart_folder: folder, filter_params: { 'participant' => ['Anna'] })
    ready = Queue.new
    release = Queue.new
    allow(first).to receive(:persist_rules).and_wrap_original do |original, conversion|
      ready << true
      release.pop
      original.call(conversion)
    end
    worker = in_thread(organisation) { first.call }
    Timeout.timeout(10) { ready.pop }
    later = in_thread(organisation) do
      Actors::SaveSmartFolderFromFilters.call(**arguments, smart_folder: SmartFolder.find(folder.id), filter_params: { 'participant' => ['Bert'] })
    end
    wait_for_lock_waiter
    release << true
    expect(worker.value).to be_success
    expect(later.value).to be_success
    expect(folder.reload.smart_folder_rules.map { |rule| JSON.parse(rule.value) }).to eq([['Bert']])
  ensure
    release << true if release
    [worker, later].compact.each { |thread| thread.join(2) || thread.kill }
  end

  it 'keeps an expert rule saved while a chip replacement waited for the lock' do
    organisation = create(:organisation)
    ActsAsTenant.current_tenant = organisation
    user = create(:user)
    project = create(:project, organisation: organisation)
    folder = create(:smart_folder, user: user, organisation: organisation, project: project, target_object_type: 'Meeting')
    folder.smart_folder_rule_groups.create!(position: 1)
          .smart_folder_rules.create!(field: 'participant', operator: 'has_any_of', value: '["Anna"]', position: 1)
    ready = Queue.new
    release = Queue.new
    # The expert editor: it holds the row lock and turns the tree into one the
    # filter bar cannot show, then commits once the chip save is waiting.
    editor = in_thread(organisation) do
      SmartFolder.find(folder.id).with_lock do
        SmartFolderRule.where(smart_folder_rule_group: folder.smart_folder_rule_groups)
                       .update_all(field: 'title', operator: 'contains', value: 'Expert only')
        ready << true
        release.pop
      end
    end
    Timeout.timeout(10) { ready.pop }
    chips = in_thread(organisation) do
      Actors::SaveSmartFolderFromFilters.call(project: project, current_user: user, operator_params: {}, name: folder.name,
                                              smart_folder: SmartFolder.find(folder.id), filter_params: { 'participant' => ['Bert'] })
    end
    wait_for_lock_waiter
    release << true
    editor.join(10)
    expect(chips.value).not_to be_success
    expect(folder.reload.smart_folder_rules.pluck(:field, :value)).to eq([['title', 'Expert only']])
  ensure
    release << true if release
    [editor, chips].compact.each { |thread| thread.join(2) || thread.kill }
  end
end
