# frozen_string_literal: true

require 'rails_helper'

# T16 (doc/billing_agentur_konto_plan.md §17.2). These specs pin the WRITE side:
# every transition of a billable seat has to leave a row behind, including the
# four hard-delete paths from §17.1, because a missing event is the one failure
# this table cannot recover from.
RSpec.describe SeatEventRecording do
  let(:organisation) { create(:organisation) }
  let(:account) { organisation.account }
  let(:user) { create(:user) }
  let(:billable_role) { create(:role, organisation: organisation, billable: true) }
  let(:guest_role) { create(:role, organisation: organisation, billable: false) }

  # Role is tenant-scoped (role.rb:25), so creating one needs a current tenant.
  # Membership and SeatEvent are not -- billing lives above the tenants -- so
  # this only enables the fixtures, it does not scope anything under test.
  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def events_for(membership)
    SeatEvent.where(organisation_id: membership.organisation_id, user_id: membership.user_id).chronological
  end

  describe 'creating a membership' do
    it 'records an activated event that counts' do
      membership = create(:membership, user: user, organisation: organisation, role: billable_role)

      expect(events_for(membership).map(&:event)).to eq([Subscriptions::Constants::SEAT_EVENT_ACTIVATED])
      expect(events_for(membership).last).to have_attributes(
        account_id: account.id,
        organisation_name: organisation.name,
        billable: true,
        counted: true
      )
    end

    it 'records NOTHING for a non-billable role -- it was never a seat' do
      membership = create(:membership, user: user, organisation: organisation, role: guest_role)

      expect(events_for(membership)).to be_empty
    end

    it 'records nothing for a membership created inactive' do
      membership = create(:membership, user: user, organisation: organisation,
                                       role: billable_role, active: false)

      expect(events_for(membership)).to be_empty
    end
  end

  describe 'the toggle cycle active -> inactive -> active' do
    # §17.5: the unique index on (user_id, organisation_id) means a reactivation
    # REUSES the row, so the state itself remembers nothing. Three events on one
    # membership row is exactly what the state cannot express.
    it 'leaves three events behind on a single membership row' do
      membership = create(:membership, user: user, organisation: organisation, role: billable_role)
      membership.update!(active: false)
      membership.update!(active: true)

      expect(events_for(membership).map(&:event)).to eq(
        [Subscriptions::Constants::SEAT_EVENT_ACTIVATED,
         Subscriptions::Constants::SEAT_EVENT_DEACTIVATED,
         Subscriptions::Constants::SEAT_EVENT_ACTIVATED]
      )
      expect(events_for(membership).map(&:counted)).to eq([true, false, true])
      expect(Membership.where(user: user, organisation: organisation).count).to eq(1)
    end

    it 'records nothing for an update that does not move the seat' do
      membership = create(:membership, user: user, organisation: organisation, role: billable_role)

      expect { membership.update!(updated_at: 1.minute.from_now) }
        .not_to(change { events_for(membership).count })
    end
  end

  describe 'a second save of the same membership in the same transaction' do
    # The same one-line thinking error the role recorder had: after_commit fires
    # once per record per transaction, attribute_before_last_save only knows the
    # LAST save. Measured before the fix: 0 rows written, stream 1, SeatCounter
    # 0. No production path saves a membership twice in one transaction today --
    # the mechanism is pinned, not a reachable incident.
    it 'still records the deactivation when a harmless save follows it' do
      membership = create(:membership, user: user, organisation: organisation, role: billable_role)

      Membership.transaction do
        membership.update!(active: false)
        membership.update!(updated_at: 1.minute.from_now)
      end

      expect(events_for(membership).map(&:event)).to eq(
        [Subscriptions::Constants::SEAT_EVENT_ACTIVATED,
         Subscriptions::Constants::SEAT_EVENT_DEACTIVATED]
      )
      expect(SeatEvent.counted_user_ids_for(account: account).size)
        .to eq(Subscriptions::SeatCounter.new(account).call)
    end
  end

  describe 'moving to a non-billable role' do
    # The plan wrote "active toggle"; that misses this path. The membership stays
    # active, but Subscriptions::SeatCounter stops counting it -- so the log has
    # to say so, or it disagrees with the counter it exists to explain.
    it 'records a deactivated event even though active never changed' do
      membership = create(:membership, user: user, organisation: organisation, role: billable_role)

      membership.update!(role: guest_role)

      expect(events_for(membership).map(&:event).last).to eq(Subscriptions::Constants::SEAT_EVENT_DEACTIVATED)
      expect(membership.reload.active).to be(true)
    end

    it 'records an activated event when moving back onto a billable role' do
      membership = create(:membership, user: user, organisation: organisation, role: guest_role)

      membership.update!(role: billable_role)

      expect(events_for(membership).map(&:event)).to eq([Subscriptions::Constants::SEAT_EVENT_ACTIVATED])
    end
  end

  describe 'the frozen billable flag' do
    it 'is not rewritten when the role changes its flag afterwards' do
      membership = create(:membership, user: user, organisation: organisation, role: billable_role)
      event = events_for(membership).last

      billable_role.update!(billable: false)

      expect(event.reload.billable).to be(true)
    end
  end

  describe 'removal paths' do
    it 'records a removed event on destroy' do
      membership = create(:membership, user: user, organisation: organisation, role: billable_role)

      membership.destroy!

      expect(events_for(membership).map(&:event)).to eq(
        [Subscriptions::Constants::SEAT_EVENT_ACTIVATED, Subscriptions::Constants::SEAT_EVENT_REMOVED]
      )
      expect(events_for(membership).last.counted).to be(false)
    end

    it 'survives the account deletion path (memberships.destroy_all)' do
      membership = create(:membership, user: user, organisation: organisation, role: billable_role)

      user.soft_delete_and_anonymize!

      expect(events_for(membership).map(&:event).last).to eq(Subscriptions::Constants::SEAT_EVENT_REMOVED)
      expect(Membership.where(user_id: user.id)).to be_empty
    end

    it 'survives the organisation cascade and stays attributable' do
      # The hard case: at after_commit time the organisations row is gone, so
      # account_id and the name have to come from the before_destroy snapshot.
      create(:membership, user: user, organisation: organisation, role: billable_role)
      org_name = organisation.name
      org_id = organisation.id

      organisation.destroy!

      removal = SeatEvent.where(organisation_id: org_id, event: Subscriptions::Constants::SEAT_EVENT_REMOVED).last
      expect(removal).to have_attributes(
        account_id: account.id,
        organisation_name: org_name,
        user_id: user.id
      )
      expect(removal.organisation).to be_nil
      expect(removal.organisation_deleted?).to be(true)
    end
  end

  describe 'an organisation without an account' do
    # Structurally impossible (AccountAutoAssignable), so this pins the
    # trade-off rather than the happy path: the membership write must NOT fail
    # because the billing log cannot resolve an account.
    it 'does not break the membership write' do
      organisation.update_column(:account_id, nil)
      allow(Rails.logger).to receive(:error)

      expect { create(:membership, user: user, organisation: organisation, role: billable_role) }
        .not_to raise_error

      membership = Membership.find_by!(user: user, organisation: organisation)
      expect(events_for(membership)).to be_empty
      expect(Rails.logger).to have_received(:error).with(/SeatEvent skipped/)
    end
  end

  describe 'no write path bypasses the callbacks' do
    # §17.2 relies on every removal path running callbacks. delete_all/update_all
    # would skip them silently, so the absence is asserted rather than trusted to
    # a comment (reference_prove_absence_positively).
    #
    # Scoped to the statement, not to the file: `memberships` anywhere before the
    # call on the same line, so the realistic
    # `org.memberships.where(active: true).update_all(...)` is caught while a
    # `roles.where(...).update_all(...)` two lines below a memberships mention is
    # not. LIMIT, stated rather than pretended: a chain broken across lines slips
    # through. That is why the association check below exists -- it tests the
    # mechanism, which no regex can see.
    it 'has no delete_all or update_all written on memberships' do
      hits = Dir.glob(Rails.root.join('{app,lib}/**/*.rb')).select do |path|
        File.readlines(path).any? do |line|
          next false if line.strip.start_with?('#')

          line.match?(/(memberships|Membership)\b[^\n;]*?\.\s*(delete_all|update_all)\b/)
        end
      end

      expect(hits).to be_empty, "seat history would be skipped in: #{hits.join(', ')}"
    end

    # dependent: :delete_all issues a single DELETE without instantiating rows --
    # no callbacks, no events, and nothing in the source that the regex above
    # would recognise as a membership write.
    it 'no association wipes memberships with dependent: :delete_all' do
      Rails.application.eager_load!
      offenders = ApplicationRecord.descendants.filter_map do |klass|
        reflection = klass.reflect_on_association(:memberships)
        next if reflection.nil?

        "#{klass}: #{reflection.options[:dependent]}" if reflection.options[:dependent] == :delete_all
      end

      expect(offenders).to be_empty
    end

    # dependent: :nullify issues an update_all at runtime -- no callback, so a
    # role deletion would strip role_id and silently stop the seat from counting
    # (SeatCounter joins(:role)) without a `deactivated` event. Pinned rather
    # than changed: switching it is a behaviour change beyond T16. If this spec
    # ever goes red, the seat log has a hole -- see the concern header.
    it 'pins the one known blind spot: Role still nullifies its memberships' do
      expect(Role.reflect_on_association(:memberships).options[:dependent]).to eq(:nullify)
    end

    # The property, not the two classes we happen to know about: a third model on
    # this table would otherwise reopen exactly the gap the admin twin had.
    it 'every model mapped to the memberships table records seat events' do
      Rails.application.eager_load!
      on_table = ApplicationRecord.descendants.select do |klass|
        klass.table_name == 'memberships' && !klass.abstract_class?
      end

      expect(on_table).to include(Membership, Admin::Membership)
      expect(on_table.reject { |klass| klass.include?(described_class) }).to be_empty
    end
  end

  # The admin backend is a second AR class on the same table with its own save
  # cycle. These are the paths an operator actually takes.
  describe 'the admin backend twin' do
    let(:admin_organisation) { Admin::Organisation.find(organisation.id) }
    let(:admin_user) { Admin::User.find(user.id) }

    it 'records an activated event when an operator adds a member' do
      admin_user.memberships.create!(organisation: admin_organisation,
                                     role: Admin::Role.find(billable_role.id), active: true)

      events = SeatEvent.where(organisation_id: organisation.id, user_id: user.id)
      expect(events.map(&:event)).to eq([Subscriptions::Constants::SEAT_EVENT_ACTIVATED])
      expect(events.last.account_id).to eq(account.id)
    end

    it 'records a removed event on the backend account deletion path' do
      # Admin::User#soft_delete_and_anonymize! -> memberships.destroy_all, which
      # is what Admin::UsersController#destroy runs. Before the twin included the
      # concern this wrote nothing at all.
      create(:membership, user: user, organisation: organisation, role: billable_role)

      admin_user.soft_delete_and_anonymize!

      events = SeatEvent.where(organisation_id: organisation.id, user_id: user.id).chronological
      expect(events.map(&:event)).to eq(
        [Subscriptions::Constants::SEAT_EVENT_ACTIVATED, Subscriptions::Constants::SEAT_EVENT_REMOVED]
      )
    end

    it 'records a removed event when an operator destroys a single membership' do
      create(:membership, user: user, organisation: organisation, role: billable_role)

      Admin::Membership.find_by!(user_id: user.id, organisation_id: organisation.id).destroy!

      expect(SeatEvent.where(organisation_id: organisation.id, user_id: user.id).chronological.map(&:event).last)
        .to eq(Subscriptions::Constants::SEAT_EVENT_REMOVED)
    end

    # The admin twin asks ADMIN::ROLE, not ::Role.
    #
    # Asserted on the classes rather than on "it does not raise": a
    # no-tenant-set example passes with the old code too, because a model spec
    # never loses the tenant the way the controller-spec environment does. The
    # first version of this example did exactly that and stayed green when the
    # fix was reverted -- vacuum green, and caught only by running the mutation.
    #
    # The concrete regression (11 red examples with NoTenantSet) is guarded by
    # spec/controllers/admin/users_controller_spec.rb; this pins the reason.
    it 'resolves billable through Admin::Role, never through the tenant-scoped ::Role' do
      allow(Admin::Role).to receive(:find_by).and_call_original
      allow(::Role).to receive(:find_by).and_call_original

      Admin::Membership.create!(user_id: user.id, organisation_id: organisation.id,
                                role_id: billable_role.id, active: true)

      expect(Admin::Role).to have_received(:find_by).with(id: billable_role.id).at_least(:once)
      expect(::Role).not_to have_received(:find_by)
    end
  end
end
