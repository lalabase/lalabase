# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Notifications::Shared::ScopeFilter, type: :service do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    create(:membership, user: other_user, organisation: organisation)
  end

  describe '#initialize' do
    it 'stores user and organisation' do
      filter = described_class.new(user, organisation)

      expect(filter.user).to eq(user)
      expect(filter.organisation).to eq(organisation)
    end

    context 'when organisation is nil' do
      it 'falls back to user.organisations.first (nondeterministic)' do
        filter = described_class.new(user)

        expect(filter.organisation).to eq(user.organisations.first)
      end

      it 'may pick an arbitrary organisation when user has multiple' do
        create(:membership, user: user, organisation: other_organisation)

        filter = described_class.new(user)

        # Nondeterministic: depends on DB ordering
        expect(user.organisations.count).to eq(2)
        expect([organisation, other_organisation]).to include(filter.organisation)
      end
    end

    context 'when user has no organisations' do
      let(:orphan_user) { create(:user) }

      it 'sets organisation to nil' do
        filter = described_class.new(orphan_user)

        expect(filter.organisation).to be_nil
      end
    end
  end

  describe '#user_notifications' do
    it 'returns only notifications for the user in the given organisation' do
      user_notification = create(:notification,
                                 recipient: user,
                                 organisation: organisation,
                                 notifiable: create(:ticket, project: project, organisation: organisation))
      _other_user_notification = create(:notification,
                                        recipient: other_user,
                                        organisation: organisation,
                                        notifiable: create(:ticket, project: project, organisation: organisation))

      filter = described_class.new(user, organisation)

      expect(filter.user_notifications).to contain_exactly(user_notification)
    end

    it 'excludes notifications from other organisations' do
      create(:notification,
             recipient: user,
             organisation: organisation,
             notifiable: create(:ticket, project: project, organisation: organisation))

      ActsAsTenant.with_tenant(other_organisation) do
        other_project = create(:project, organisation: other_organisation)
        create(:notification,
               recipient: user,
               organisation: other_organisation,
               notifiable: create(:ticket, project: other_project, organisation: other_organisation))
      end

      filter = described_class.new(user, organisation)

      expect(filter.user_notifications.count).to eq(1)
    end
  end

  describe '#organisation_notifications' do
    it 'returns all notifications scoped to the organisation' do
      create(:notification,
             recipient: user,
             organisation: organisation,
             notifiable: create(:ticket, project: project, organisation: organisation))
      create(:notification,
             recipient: other_user,
             organisation: organisation,
             notifiable: create(:ticket, project: project, organisation: organisation))

      filter = described_class.new(user, organisation)

      expect(filter.organisation_notifications.count).to eq(2)
    end
  end

  describe '#email_notifications' do
    it 'returns only email-channel notifications for the user' do
      email_notif = create(:notification,
                           recipient: user,
                           organisation: organisation,
                           channel: 'email',
                           notifiable: create(:ticket, project: project, organisation: organisation))
      _in_app_notif = create(:notification,
                             recipient: user,
                             organisation: organisation,
                             channel: 'in_app',
                             notifiable: create(:ticket, project: project, organisation: organisation))

      filter = described_class.new(user, organisation)

      expect(filter.email_notifications).to contain_exactly(email_notif)
    end
  end

  describe '#pending_notifications' do
    it 'returns only queued and sent notifications' do
      queued = create(:notification, :unread,
                      recipient: user,
                      organisation: organisation,
                      notifiable: create(:ticket, project: project, organisation: organisation))
      _read = create(:notification, :read,
                     recipient: user,
                     organisation: organisation,
                     notifiable: create(:ticket, project: project, organisation: organisation))

      filter = described_class.new(user, organisation)
      results = filter.pending_notifications

      expect(results).to include(queued)
    end
  end

  describe '#immediate_delivery_notifications' do
    it 'uses string interpolation for user.id in SQL (SQL injection risk)' do
      filter = described_class.new(user, organisation)

      # Verify the generated SQL contains the interpolated user ID
      sql = filter.immediate_delivery_notifications.to_sql

      # BUG: user.id is interpolated directly into SQL instead of being parameterized
      expect(sql).to include("'#{user.id}'")
    end

    it 'joins with notification_preferences for immediate email delivery' do
      filter = described_class.new(user, organisation)
      sql = filter.immediate_delivery_notifications.to_sql

      expect(sql).to include('notification_preferences')
      expect(sql).to include("frequency = 'immediate'")
      expect(sql).to include("channel = 'email'")
    end
  end

  describe '#with_associations' do
    it 'includes actor, notifiable, and organisation' do
      filter = described_class.new(user, organisation)
      relation = filter.with_associations

      expect(relation.includes_values.map(&:to_s)).to include('actor', 'notifiable', 'organisation')
    end
  end

  describe '#with_email_logs' do
    it 'includes email_logs' do
      filter = described_class.new(user, organisation)
      relation = filter.with_email_logs

      expect(relation.includes_values.map(&:to_s)).to include('email_logs')
    end
  end

  describe '#with_full_context' do
    it 'includes all associations for complete context' do
      filter = described_class.new(user, organisation)
      relation = filter.with_full_context

      includes = relation.includes_values.map(&:to_s)
      expect(includes).to include('actor', 'notifiable', 'organisation', 'email_logs')
    end
  end

  describe '#for_fanout_service' do
    it 'executes block within tenant context' do
      filter = described_class.new(user, organisation)
      tenant_inside_block = nil

      filter.for_fanout_service do
        tenant_inside_block = ActsAsTenant.current_tenant
      end

      expect(tenant_inside_block).to eq(organisation)
    end

    it 'is a pass-through wrapper around with_tenant_context (code smell)' do
      filter = described_class.new(user, organisation)
      result_fanout = nil
      result_tenant = nil

      filter.for_fanout_service { result_fanout = :executed }
      filter.with_tenant_context { result_tenant = :executed }

      # Both do exactly the same thing — for_fanout_service adds no value
      expect(result_fanout).to eq(result_tenant)
    end
  end

  describe '#for_suppression_check' do
    it 'returns a relation with includes and model-level recent scope (ordering)' do
      create(:notification,
             recipient: user,
             organisation: organisation,
             created_at: 1.hour.ago,
             notifiable: create(:ticket, project: project, organisation: organisation))
      create(:notification,
             recipient: user,
             organisation: organisation,
             created_at: 5.minutes.ago,
             notifiable: create(:ticket, project: project, organisation: organisation))

      filter = described_class.new(user, organisation)
      result = filter.for_suppression_check

      # `.recent` here is Notification model scope (ordering), NOT the private ScopeFilter method (filtering)
      # The private `recent` method in ScopeFilter (line 142) is dead code
      expect(result.count).to eq(2) # all notifications, not just last 24h
      expect(result.first.created_at).to be > result.last.created_at # ordered desc
    end
  end

  describe '#execute_scoped' do
    it 'executes a scope method within tenant context' do
      create(:notification,
             recipient: user,
             organisation: organisation,
             notifiable: create(:ticket, project: project, organisation: organisation))

      filter = described_class.new(user, organisation)
      count = nil

      filter.execute_scoped(:user_notifications) do |scope|
        count = scope.count
      end

      expect(count).to eq(1)
    end

    it 'accepts any method name via send — including private methods (unsafe)' do
      filter = described_class.new(user, organisation)

      # Can call private methods through execute_scoped
      expect do
        filter.execute_scoped(:recent) { |scope| scope }
      end.not_to raise_error
    end

    it 'can call arbitrary methods like class (security risk)' do
      filter = described_class.new(user, organisation)

      result = nil
      filter.execute_scoped(:class) { |scope| result = scope }

      # send(:class) returns the class object — no validation on method name
      expect(result).to eq(described_class)
    end

    it 'returns nil when no block given' do
      filter = described_class.new(user, organisation)
      result = filter.execute_scoped(:user_notifications)

      expect(result).to be_nil
    end
  end

  describe '#scope_summary' do
    it 'returns a hash with notification counts' do
      create(:notification,
             recipient: user,
             organisation: organisation,
             channel: 'email',
             state: 'queued',
             created_at: 1.hour.ago,
             notifiable: create(:ticket, project: project, organisation: organisation))
      create(:notification,
             recipient: user,
             organisation: organisation,
             channel: 'in_app',
             state: 'read',
             created_at: 2.days.ago,
             notifiable: create(:ticket, project: project, organisation: organisation))

      filter = described_class.new(user, organisation)
      summary = filter.scope_summary

      expect(summary[:user_id]).to eq(user.id)
      expect(summary[:organisation_id]).to eq(organisation.id)
      expect(summary[:total_notifications]).to eq(2)
      expect(summary[:email_notifications]).to eq(1)
      expect(summary[:pending_notifications]).to eq(1) # only queued one
      expect(summary[:recent_notifications]).to eq(1)  # only last 24h
    end

    it 'makes 4 separate DB queries for counts (performance concern)' do
      filter = described_class.new(user, organisation)

      query_count = 0
      counter = lambda { |_name, _start, _finish, _id, payload|
        query_count += 1 if payload[:sql]&.include?('COUNT')
      }

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        filter.scope_summary
      end

      expect(query_count).to eq(4)
    end
  end

  describe '#valid_user_organisation_combo?' do
    it 'returns true when user belongs to organisation' do
      filter = described_class.new(user, organisation)

      expect(filter.valid_user_organisation_combo?).to be true
    end

    it 'returns false when user does not belong to organisation' do
      filter = described_class.new(user, other_organisation)

      expect(filter.valid_user_organisation_combo?).to be false
    end

    it 'returns false when user is nil' do
      filter = described_class.new(user, organisation)
      filter.instance_variable_set(:@user, nil)

      expect(filter.valid_user_organisation_combo?).to be false
    end

    it 'returns false when organisation is nil' do
      filter = described_class.new(user, nil)
      # organisation falls back to user.organisations.first
      # so we need to force nil
      filter.instance_variable_set(:@organisation, nil)

      expect(filter.valid_user_organisation_combo?).to be false
    end

    it 'uses include? which loads all organisations into memory (N+1 risk)' do
      filter = described_class.new(user, organisation)

      # include? triggers a collection load, exists? would be more efficient
      expect(user.organisations).to receive(:include?).with(organisation).and_call_original

      filter.valid_user_organisation_combo?
    end
  end

  describe '#has_access_to_organisation?' do
    it 'returns true when user belongs to organisation' do
      filter = described_class.new(user, organisation)

      expect(filter.has_access_to_organisation?).to be true
    end

    it 'returns true when organisation is nil (different semantic than valid_user_organisation_combo?)' do
      filter = described_class.new(user, organisation)
      filter.instance_variable_set(:@organisation, nil)

      # BUG/Inconsistency: returns true when org is nil
      # valid_user_organisation_combo? returns false when org is nil
      expect(filter.has_access_to_organisation?).to be true
    end

    it 'returns false when user does not belong to organisation' do
      filter = described_class.new(user, other_organisation)

      expect(filter.has_access_to_organisation?).to be false
    end

    it 'uses exists? instead of include? (more efficient)' do
      filter = described_class.new(user, organisation)

      expect(user.organisations).to receive(:exists?).with(organisation.id).and_call_original

      filter.has_access_to_organisation?
    end
  end

  describe 'private #recent method (dead code)' do
    it 'is a private method that filters by 24h but is never called' do
      filter = described_class.new(user, organisation)

      # The private method exists and filters by time
      private_recent_sql = filter.send(:recent).to_sql
      expect(private_recent_sql).to include('created_at >')

      # for_suppression_check uses Notification.recent (ordering scope) instead
      # because with_associations returns an AR::Relation which delegates to the model scope
      suppression_sql = filter.for_suppression_check.to_sql
      expect(suppression_sql).to include('ORDER BY')
      # The suppression query does NOT contain a time-based WHERE filter
      expect(suppression_sql).not_to include('created_at >')
    end
  end

  describe 'code smell: class is not used anywhere in the codebase' do
    it 'is never instantiated in app code (only defined)' do
      # Search app/ directory for ScopeFilter.new calls (excluding the definition file itself)
      app_files = Dir.glob(Rails.root.join('app/**/*.rb'))
      usages = app_files.reject { |f| f.end_with?('scope_filter.rb') }.select do |file|
        File.read(file).include?('ScopeFilter')
      end

      expect(usages).to be_empty
    end
  end
end
