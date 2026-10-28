# frozen_string_literal: true

require 'rails_helper'

# The three special-case serializers carry real logic (join, filtering,
# per-tenant lookup) — each decision point gets a test that dies if the logic
# is "simplified" away:
# - EmailLogs: BOTH lookup branches (notification join + legacy address
#   fallback) and recipient isolation
# - UserActivities: the attribute_changes whitelist (third-party context must
#   never pass through)
# - Memberships: role via role_id vs legacy string column
RSpec.describe 'UserDataExports::Serializers' do
  let(:user) { create(:user) }
  let(:organisation) { create(:organisation) }

  describe UserDataExports::Serializers::EmailLogsSerializer do
    it 'finds logs via the notification recipient join (the reliable path)' do
      ActsAsTenant.with_tenant(organisation) do
        notification = create(:notification, recipient: user, organisation: organisation)
        create(:email_log, notification: notification, organisation: organisation,
                           recipient_email: nil, subject: 'Join-Treffer')

        subjects = described_class.call(nil, user).map { |row| row['subject'] }
        expect(subjects).to contain_exactly('Join-Treffer')
      end
    end

    it 'finds legacy logs via the recipient_email fallback' do
      ActsAsTenant.with_tenant(organisation) do
        foreign_notification = create(:notification, recipient: create(:user), organisation: organisation)
        create(:email_log, notification: foreign_notification, organisation: organisation,
                           recipient_email: user.email, subject: 'Legacy-Treffer')

        subjects = described_class.call(nil, user).map { |row| row['subject'] }
        expect(subjects).to contain_exactly('Legacy-Treffer')
      end
    end

    it 'never returns other recipients\' logs' do
      ActsAsTenant.with_tenant(organisation) do
        foreign_notification = create(:notification, recipient: create(:user), organisation: organisation)
        create(:email_log, notification: foreign_notification, organisation: organisation,
                           recipient_email: 'jemand-anderes@example.com', subject: 'Fremde Mail')

        expect(described_class.call(nil, user)).to be_empty
      end
    end

    it 'does not duplicate a log matched by BOTH branches' do
      ActsAsTenant.with_tenant(organisation) do
        notification = create(:notification, recipient: user, organisation: organisation)
        create(:email_log, notification: notification, organisation: organisation,
                           recipient_email: user.email, subject: 'Doppelt getroffen')

        expect(described_class.call(nil, user).size).to eq(1)
      end
    end

    it 'exports metadata only — never body columns' do
      ActsAsTenant.with_tenant(organisation) do
        notification = create(:notification, recipient: user, organisation: organisation)
        create(:email_log, notification: notification, organisation: organisation,
                           body_text: 'GEHEIMER MAILINHALT', subject: 'Metadaten')

        rows = described_class.call(nil, user)
        expect(rows.first.keys).to match_array(described_class::ATTRIBUTES)
        expect(rows.to_json).not_to include('GEHEIMER MAILINHALT')
      end
    end
  end

  describe UserDataExports::Serializers::UserActivitiesSerializer do
    it 'passes own identity fields through the changes whitelist and drops everything else' do
      create(:user_activity, user: user, organisation: organisation,
                             action: 'email_changed',
                             attribute_changes: {
                               'email' => %w[alt@example.com neu@example.com],
                               'admin_name' => 'Chef Dritter',      # third-party context
                               'role_context' => 'internes Detail'  # must never leak
                             })

      row = described_class.call(nil, user).first
      expect(row['changes'].keys).to contain_exactly('email')
      expect(row['changes'].to_json).not_to include('Chef Dritter', 'internes Detail')
      # ATTRIBUTES is the audited contract the secret guard checks — emitted
      # keys must match it EXACTLY, or a later added key would bypass the guard.
      expect(row.keys).to match_array(described_class::ATTRIBUTES)
    end

    it 'only returns the requesting user\'s activities' do
      create(:user_activity, user: create(:user), organisation: organisation, ip_address: '10.9.9.9')

      expect(described_class.call(nil, user)).to be_empty
    end

    it 'survives activities without an organisation (global events like login)' do
      create(:user_activity, user: user, organisation: nil)

      rows = described_class.call(nil, user)
      expect(rows.first['organisation_name']).to be_nil
    end
  end

  describe UserDataExports::Serializers::MembershipsSerializer do
    it 'resolves the role title inside the org tenant (role_id path)' do
      role = ActsAsTenant.with_tenant(organisation) { create(:role, title: 'Projektleiter', organisation: organisation) }
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: role)
      end

      row = described_class.call(nil, user).first
      expect(row['role_title']).to eq('Projektleiter')
      expect(row['organisation_name']).to eq(organisation.name)
      # ATTRIBUTES is the audited contract the secret guard checks — emitted
      # keys must match it EXACTLY, or a later added key would bypass the guard.
      expect(row.keys).to match_array(described_class::ATTRIBUTES)
    end

    it 'exports the legacy string column when no Role record is linked' do
      membership = ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation)
      end
      # deliberately writing the
      # legacy string column that the association reader shadows
      membership.update_column(:role_id, nil)
      membership.update_column(:role, 'legacy-admin')

      row = described_class.call(nil, user).first
      expect(row['role_title']).to be_nil
      expect(row['legacy_role']).to eq('legacy-admin')
    end
  end

  # The person row linked to the account: the additional details are part of
  # it, as stored (kind, label, value).
  describe 'the people source' do
    it 'exports the additional details of the own row' do
      details = [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '+49 170 1234567' }]
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, active: true)
        create(:person, organisation: organisation, user: user, name: 'Erika Beispiel', additional_details: details)

        source = UserDataExports::Registry::SOURCES.find { |entry| entry.key == :people }
        row = UserDataExports::GenericSerializer.call(source, user).first

        expect(row['additional_details']).to eq(details)
      end
    end
  end
end
