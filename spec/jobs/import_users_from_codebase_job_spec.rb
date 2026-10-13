# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportUsersFromCodebaseJob, :ci_guard, type: :job do
  let(:organisation) { create(:organisation) }
  let(:importing_user) { create(:user, organisation: organisation) }
  let(:default_role) { create(:role, organisation: organisation, is_default: true) }
  let(:specific_role) { create(:role, organisation: organisation, title: 'Specific Role') }

  let(:users_xml) do
    <<~XML
      <users-users>
        <users-user>
          <id>101</id>
          <username>jdoe</username>
          <email-address>john@example.com</email-address>
          <full-name>John Doe</full-name>
          <role><id>1</id><name>Member</name><account-administrator>false</account-administrator></role>
          <company><id>10</id><name>TestCo</name></company>
        </users-user>
      </users-users>
    XML
  end

  let(:import_file) do
    ActsAsTenant.with_tenant(organisation) do
      create(:codebase_import_file,
             organisation: organisation,
             user: importing_user,
             file_type: 'users',
             original_filename: 'users.xml',
             file_content: users_xml,
             status: 'uploaded',
             metadata: {})
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def perform_job(import_file_id, user_actions, user_roles, importing_user_id)
    described_class.new.perform(import_file_id, user_actions, user_roles, importing_user_id)
  end

  # -- Helper for multi-user XML --
  def build_users_xml(users)
    entries = users.map do |u|
      <<~ENTRY
        <users-user>
          <id>#{u[:id]}</id>
          <username>#{u[:username] || ''}</username>
          <email-address>#{u[:email]}</email-address>
          <full-name>#{u[:full_name] || ''}</full-name>
          <role><id>1</id><name>Member</name><account-administrator>false</account-administrator></role>
          <company><id></id><name></name></company>
        </users-user>
      ENTRY
    end
    "<users-users>#{entries.join}</users-users>"
  end

  describe '#perform' do
    context 'status transitions' do
      it 'sets status to processing then to processed on success' do
        default_role
        perform_job(import_file.id, { '101' => 'skip' }, {}, importing_user.id)

        import_file.reload
        expect(import_file.status).to eq('processed')
        expect(import_file.processed_at).to be_present
      end

      it 'sets status to error on failure and re-raises' do
        allow_any_instance_of(CodebaseImportFile).to receive(:parsed_data).and_raise(RuntimeError, 'boom')

        expect do
          perform_job(import_file.id, {}, {}, importing_user.id)
        end.to raise_error(RuntimeError, 'boom')

        import_file.reload
        expect(import_file.status).to eq('error')
        expect(import_file.metadata['error']).to eq('boom')
      end
    end

    context 'with create action' do
      it 'creates a new user, membership and mapping' do
        default_role
        # Materialize lazy-lets before counting
        file_id = import_file.id
        user_id = importing_user.id

        expect do
          perform_job(file_id, { '101' => 'create' }, {}, user_id)
        end.to change(User, :count).by(1)
                                   .and change(Membership, :count).by(1)
                                                                  .and change(CodebaseImportMapping, :count).by(1)

        new_user = User.find_by(email: 'john@example.com')
        expect(new_user.first_name).to eq('John')
        expect(new_user.last_name).to eq('Doe')
        expect(new_user.invited_by_user).to eq(importing_user)
        expect(new_user.invited_by_org).to eq(organisation)

        membership = Membership.find_by(user: new_user, organisation: organisation)
        expect(membership.active).to be false

        mapping = CodebaseImportMapping.find_by(codebase_id: '101', entity_type: 'User')
        expect(mapping.local_id).to eq(new_user.id)
        expect(mapping.mapping_data['action']).to eq('created')

        import_file.reload
        results = import_file.metadata['import_results']
        expect(results['created']).to eq(1)
        expect(results['total']).to eq(1)
      end

      # Regression: :confirmable turned every import row into a confirmation
      # mail to somebody who never signed up — and, once the grace period ran
      # out, into a locked account. An import is an admin action over a
      # vouched-for address list, so the imported user counts as confirmed and
      # receives no mail at all.
      it 'creates the user already confirmed and sends no confirmation mail' do
        default_role
        file_id = import_file.id
        user_id = importing_user.id

        expect do
          perform_job(file_id, { '101' => 'create' }, {}, user_id)
        end.not_to(change { ActionMailer::Base.deliveries.size })

        expect(User.find_by(email: 'john@example.com').confirmed?).to be(true)
      end

      it 'uses the specified role when role_id is provided' do
        specific_role
        default_role

        perform_job(import_file.id, { '101' => 'create' }, { '101' => specific_role.id }, importing_user.id)

        new_user = User.find_by(email: 'john@example.com')
        membership = Membership.find_by(user: new_user, organisation: organisation)
        expect(membership.role).to eq(specific_role)
      end

      it 'falls back to default role when role_id is nil' do
        default_role

        perform_job(import_file.id, { '101' => 'create' }, {}, importing_user.id)

        new_user = User.find_by(email: 'john@example.com')
        membership = Membership.find_by(user: new_user, organisation: organisation)
        expect(membership.role).to eq(default_role)
      end

      it 'falls back to default role when role_id is blank string' do
        default_role

        perform_job(import_file.id, { '101' => 'create' }, { '101' => '' }, importing_user.id)

        new_user = User.find_by(email: 'john@example.com')
        membership = Membership.find_by(user: new_user, organisation: organisation)
        expect(membership.role).to eq(default_role)
      end
    end

    context 'with map action' do
      let(:existing_user) { create(:user, organisation: organisation) }

      it 'creates a mapping to the existing user' do
        file_id = import_file.id
        user_id = importing_user.id
        target_id = existing_user.id

        expect do
          perform_job(file_id, { '101' => "map:#{target_id}" }, {}, user_id)
        end.to change(CodebaseImportMapping, :count).by(1)
                                                    .and change(User, :count).by(0)

        mapping = CodebaseImportMapping.find_by(codebase_id: '101', entity_type: 'User')
        expect(mapping.local_id).to eq(existing_user.id)
        expect(mapping.mapping_data['action']).to eq('mapped')

        import_file.reload
        results = import_file.metadata['import_results']
        expect(results['mapped']).to eq(1)
      end

      it 'counts as failed when target user does not exist' do
        non_existent_id = SecureRandom.uuid

        perform_job(import_file.id, { '101' => "map:#{non_existent_id}" }, {}, importing_user.id)

        import_file.reload
        results = import_file.metadata['import_results']
        expect(results['failed']).to eq(1)
        expect(results['mapped']).to eq(0)
      end

      # The select only offers members, but the id comes from the request. Mapping onto
      # an account of another organisation put that person's name and avatar on imported
      # tickets, posts and time entries here.
      it 'refuses a target user who is not a member of the organisation' do
        foreign_user = create(:user, organisation: create(:organisation))

        expect do
          perform_job(import_file.id, { '101' => "map:#{foreign_user.id}" }, {}, importing_user.id)
        end.not_to change(CodebaseImportMapping, :count)

        results = import_file.reload.metadata['import_results']
        expect(results['failed']).to eq(1)
        expect(results['mapped']).to eq(0)
      end
    end

    context 'with skip action' do
      it 'increments skipped counter without creating records' do
        file_id = import_file.id
        user_id = importing_user.id

        expect do
          perform_job(file_id, { '101' => 'skip' }, {}, user_id)
        end.to change(User, :count).by(0)
                                   .and change(CodebaseImportMapping, :count).by(0)

        import_file.reload
        results = import_file.metadata['import_results']
        expect(results['skipped']).to eq(1)
      end
    end

    context 'with unknown action' do
      it 'counts as failed and logs a warning' do
        expect(Rails.logger).to receive(:warn).with(/Unknown action 'foobar'/)

        perform_job(import_file.id, { '101' => 'foobar' }, {}, importing_user.id)

        import_file.reload
        results = import_file.metadata['import_results']
        expect(results['failed']).to eq(1)
      end
    end

    context 'with nil action (no entry in user_actions)' do
      it 'counts as failed' do
        expect(Rails.logger).to receive(:warn).with(/Unknown action ''/)

        perform_job(import_file.id, {}, {}, importing_user.id)

        import_file.reload
        results = import_file.metadata['import_results']
        expect(results['failed']).to eq(1)
      end
    end

    context 'with mixed actions' do
      let(:existing_user) { create(:user, organisation: organisation) }

      let(:multi_users_xml) do
        build_users_xml([
                          { id: '1', email: 'create@example.com', full_name: 'Create User' },
                          { id: '2', email: 'map@example.com', full_name: 'Map User' },
                          { id: '3', email: 'skip@example.com', full_name: 'Skip User' },
                          { id: '4', email: 'unknown@example.com', full_name: 'Unknown User' }
                        ])
      end

      let(:import_file) do
        ActsAsTenant.with_tenant(organisation) do
          create(:codebase_import_file,
                 organisation: organisation,
                 user: importing_user,
                 file_type: 'users',
                 original_filename: 'users.xml',
                 file_content: multi_users_xml,
                 status: 'uploaded',
                 metadata: {})
        end
      end

      it 'handles all action types correctly in a single run' do
        default_role

        user_actions = {
          '1' => 'create',
          '2' => "map:#{existing_user.id}",
          '3' => 'skip',
          '4' => 'bogus'
        }

        perform_job(import_file.id, user_actions, {}, importing_user.id)

        import_file.reload
        results = import_file.metadata['import_results']
        expect(results['total']).to eq(4)
        expect(results['created']).to eq(1)
        expect(results['mapped']).to eq(1)
        expect(results['skipped']).to eq(1)
        expect(results['failed']).to eq(1)
      end
    end

    context 'with empty parsed data' do
      let(:import_file) do
        ActsAsTenant.with_tenant(organisation) do
          create(:codebase_import_file,
                 organisation: organisation,
                 user: importing_user,
                 file_type: 'users',
                 original_filename: 'users.xml',
                 file_content: '<users-users></users-users>',
                 status: 'uploaded',
                 metadata: {})
        end
      end

      it 'completes with zero counts' do
        perform_job(import_file.id, {}, {}, importing_user.id)

        import_file.reload
        expect(import_file.status).to eq('processed')
        results = import_file.metadata['import_results']
        expect(results['total']).to eq(0)
      end
    end

    context 'when parsed_data returns nil' do
      let(:import_file) do
        ActsAsTenant.with_tenant(organisation) do
          create(:codebase_import_file,
                 organisation: organisation,
                 user: importing_user,
                 file_type: 'users',
                 original_filename: 'users.xml',
                 file_content: '<<<INVALID XML>>>',
                 status: 'uploaded',
                 metadata: {})
        end
      end

      it 'handles nil gracefully and completes with zero counts' do
        perform_job(import_file.id, {}, {}, importing_user.id)

        import_file.reload
        expect(import_file.status).to eq('processed')
        results = import_file.metadata['import_results']
        expect(results['total']).to eq(0)
      end
    end

    context 'record not found' do
      it 'raises when import_file does not exist' do
        expect do
          perform_job(SecureRandom.uuid, {}, {}, importing_user.id)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'raises when importing_user does not exist' do
        expect do
          perform_job(import_file.id, {}, {}, SecureRandom.uuid)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'user creation failure' do
      it 'counts as failed when email is duplicate' do
        default_role
        create(:user, email: 'john@example.com')

        perform_job(import_file.id, { '101' => 'create' }, {}, importing_user.id)

        import_file.reload
        results = import_file.metadata['import_results']
        expect(results['failed']).to eq(1)
        expect(results['created']).to eq(0)
        expect(import_file.status).to eq('processed')
      end

      it 'rolls back user and membership on mapping failure (transaction)' do
        default_role
        file_id = import_file.id
        user_id = importing_user.id

        # Provoke CodebaseImportMapping.create! failure after User + Membership succeed
        allow(CodebaseImportMapping).to receive(:create!).and_raise(
          ActiveRecord::RecordInvalid.new(CodebaseImportMapping.new)
        )

        expect do
          perform_job(file_id, { '101' => 'create' }, {}, user_id)
        end.to change(User, :count).by(0)
                                   .and change(Membership, :count).by(0)

        import_file.reload
        results = import_file.metadata['import_results']
        expect(results['failed']).to eq(1)
      end
    end

    context 'when role_id points to non-existent role' do
      it 'counts as failed' do
        perform_job(import_file.id, { '101' => 'create' }, { '101' => SecureRandom.uuid }, importing_user.id)

        import_file.reload
        results = import_file.metadata['import_results']
        expect(results['failed']).to eq(1)
      end
    end

    context 'idempotency (duplicate mapping)' do
      it 'counts second create attempt as failed due to unique index' do
        default_role

        # First run: success
        perform_job(import_file.id, { '101' => 'create' }, {}, importing_user.id)
        import_file.reload
        expect(import_file.metadata['import_results']['created']).to eq(1)

        # Reset status so job can run again
        import_file.update!(status: 'uploaded', metadata: {})

        # Build new XML with same codebase_id but different email to avoid email uniqueness
        new_xml = build_users_xml([{ id: '101', email: 'john2@example.com', full_name: 'John Again' }])
        import_file.update!(file_content: new_xml)

        # Second run: mapping already exists → unique constraint violation → failed
        perform_job(import_file.id, { '101' => 'create' }, {}, importing_user.id)

        import_file.reload
        results = import_file.metadata['import_results']
        expect(results['failed']).to eq(1)
        expect(results['created']).to eq(0)
      end
    end

    context 'metadata merging' do
      it 'preserves existing metadata when adding import_results' do
        import_file.update!(metadata: { 'existing_key' => 'existing_value' })

        perform_job(import_file.id, { '101' => 'skip' }, {}, importing_user.id)

        import_file.reload
        expect(import_file.metadata['existing_key']).to eq('existing_value')
        expect(import_file.metadata['import_results']).to be_present
      end

      it 'preserves existing metadata when setting error' do
        import_file.update!(metadata: { 'existing_key' => 'value' })
        allow_any_instance_of(CodebaseImportFile).to receive(:parsed_data).and_raise(RuntimeError, 'test error')

        expect do
          perform_job(import_file.id, {}, {}, importing_user.id)
        end.to raise_error(RuntimeError)

        import_file.reload
        expect(import_file.metadata['existing_key']).to eq('value')
        expect(import_file.metadata['error']).to eq('test error')
      end
    end
  end

  describe '#extract_name_parts (via create action)' do
    before { default_role }

    def create_user_with_name(full_name)
      xml = build_users_xml([{ id: '1', email: "test-#{SecureRandom.hex(4)}@example.com", full_name: full_name }])
      file = ActsAsTenant.with_tenant(organisation) do
        create(:codebase_import_file,
               organisation: organisation,
               user: importing_user,
               file_type: 'users',
               original_filename: 'u.xml',
               file_content: xml,
               status: 'uploaded',
               metadata: {})
      end
      perform_job(file.id, { '1' => 'create' }, {}, importing_user.id)
      User.order(created_at: :desc).first
    end

    it 'splits two-word name into first and last' do
      user = create_user_with_name('Alice Smith')
      expect(user.first_name).to eq('Alice')
      expect(user.last_name).to eq('Smith')
    end

    it 'handles single-word name' do
      user = create_user_with_name('Madonna')
      expect(user.first_name).to eq('Madonna')
      expect(user.last_name).to eq('')
    end

    it 'handles multi-part last name' do
      user = create_user_with_name('Maria von der Leyen')
      expect(user.first_name).to eq('Maria')
      expect(user.last_name).to eq('von der Leyen')
    end

    it 'handles extra whitespace' do
      user = create_user_with_name('  Alice   Smith  ')
      expect(user.first_name).to eq('Alice')
      expect(user.last_name).to eq('Smith')
    end

    it 'handles empty name' do
      user = create_user_with_name('')
      expect(user.first_name).to eq('')
      expect(user.last_name).to eq('')
    end
  end
end
