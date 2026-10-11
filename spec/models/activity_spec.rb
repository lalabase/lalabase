# frozen_string_literal: true

# == Schema Information
#
# Table name: activities
#
#  id                :uuid             not null, primary key
#  action            :string           not null
#  attribute_changes :jsonb
#  key               :string           not null
#  parameters        :jsonb
#  secondary_type    :string
#  trackable_type    :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  actor_id          :uuid             not null
#  organisation_id   :uuid             not null
#  secondary_id      :uuid
#  trackable_id      :uuid             not null
#
# Indexes
#
#  index_activities_on_actor_and_time       (actor_id,created_at)
#  index_activities_on_actor_id             (actor_id)
#  index_activities_on_org_action_and_time  (organisation_id,action,created_at)
#  index_activities_on_org_key_and_time     (organisation_id,key,created_at)
#  index_activities_on_organisation_id      (organisation_id)
#  index_activities_on_secondary            (secondary_type,secondary_id)
#  index_activities_on_secondary_ref        (secondary_type,secondary_id)
#  index_activities_on_trackable            (trackable_type,trackable_id)
#  index_activities_on_trackable_and_time   (trackable_type,trackable_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (actor_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
require 'rails_helper'

RSpec.describe Activity, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, first_name: 'Anna', last_name: 'Schmidt') }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) do
    t = build(:ticket, project: project, organisation: organisation)
    t.define_singleton_method(:track_activities?) { false }
    t.save!
    t
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    Current.user = user
  end

  # ---------------------------------------------------------------------------
  # Helper: creates an Activity without triggering notification side effects
  # ---------------------------------------------------------------------------
  def create_activity(attrs = {})
    trackable_object = attrs[:trackable] || ticket

    default_attrs = {
      actor: user,
      organisation: organisation,
      trackable: trackable_object,
      action: 'created',
      key: 'ticket.created',
      parameters: {},
      skip_notifications: true
    }

    Activity.create!(default_attrs.merge(attrs))
  end

  # ===========================================================================
  # Associations
  # ===========================================================================
  describe 'associations' do
    it { is_expected.to belong_to(:actor).class_name('User') }
    it { is_expected.to belong_to(:trackable) }
    it { is_expected.to belong_to(:secondary).optional }
    it { is_expected.to have_many(:outbox_events).dependent(:delete_all) }
  end

  # ===========================================================================
  # Validations
  # ===========================================================================
  describe 'validations' do
    it { is_expected.to validate_presence_of(:action) }
    it { is_expected.to validate_presence_of(:key) }
  end

  # ===========================================================================
  # Callbacks
  # ===========================================================================
  describe 'callbacks' do
    describe '#set_key' do
      it 'derives key from trackable_type and action' do
        activity = Activity.new(
          actor: user, organisation: organisation,
          trackable: ticket, action: 'created'
        )
        activity.valid?
        expect(activity.key).to eq('ticket.created')
      end

      it 'does not override a manually set key' do
        activity = Activity.new(
          actor: user, organisation: organisation,
          trackable: ticket, action: 'created', key: 'custom.key'
        )
        activity.valid?
        expect(activity.key).to eq('custom.key')
      end

      it 'leaves key nil when trackable_type is nil' do
        activity = Activity.new(action: 'created', actor: user, organisation: organisation)
        activity.valid?
        expect(activity.key).to be_nil
      end

      it 'leaves key nil when action is nil' do
        activity = Activity.new(trackable: ticket, actor: user, organisation: organisation)
        activity.valid?
        expect(activity.key).to be_nil
      end

      it 'handles namespaced trackable types' do
        activity = Activity.new(
          actor: user, organisation: organisation,
          trackable: project, action: 'updated'
        )
        activity.valid?
        expect(activity.key).to eq('project.updated')
      end
    end

    # Until 2026-10-02 every activity enqueued two Turbo broadcasts to streams
    # nothing subscribed to, and during a signup both raised NoTenantSet in the
    # worker. They were removed; this keeps them from coming back unheard.
    describe 'broadcasts' do
      it 'enqueues no Turbo broadcast job when an activity is created' do
        with_test_queue_adapter do
          expect { create_activity }.not_to have_enqueued_job(Turbo::Streams::ActionBroadcastJob)
        end
      end

      # The control for the example above: the same setup does see a
      # broadcast job when one is enqueued, so the negative claim is measured.
      it 'would see a broadcast job if an activity enqueued one' do
        with_test_queue_adapter do
          activity = create_activity
          expect { activity.broadcast_prepend_later_to('control', target: 'control') }
            .to have_enqueued_job(Turbo::Streams::ActionBroadcastJob)
        end
      end
    end

    describe '#create_notification_outbox_event' do
      it 'calls OutboxEvent.create_from_activity! when skip_notifications is false' do
        activity = create_activity
        activity.skip_notifications = false
        expect(OutboxEvent).to receive(:create_from_activity!).with(activity)
        activity.send(:create_notification_outbox_event)
      end

      it 'skips outbox event when skip_notifications is true' do
        activity = create_activity
        activity.skip_notifications = true
        expect(OutboxEvent).not_to receive(:create_from_activity!)
        activity.send(:create_notification_outbox_event)
      end

      it 'logs error and does not raise when outbox creation fails' do
        activity = create_activity
        activity.skip_notifications = false
        allow(OutboxEvent).to receive(:create_from_activity!).and_raise(StandardError, 'DB error')

        expect(Rails.logger).to receive(:error).with(/Failed to create outbox event.*DB error/)
        expect { activity.send(:create_notification_outbox_event) }.not_to raise_error
      end
    end
  end

  # ===========================================================================
  # Scopes
  # ===========================================================================
  describe 'scopes' do
    # Use a dedicated ticket for scope tests and clean up leaked activities
    let!(:scope_ticket) do
      t = build(:ticket, project: project, organisation: organisation)
      t.define_singleton_method(:track_activities?) { false }
      t.save!
      Activity.where(trackable: t).destroy_all
      t
    end

    let!(:created_activity) do
      create_activity(trackable: scope_ticket, action: 'created', key: 'ticket.created', created_at: 1.day.ago)
    end
    let!(:updated_activity) do
      create_activity(trackable: scope_ticket, action: 'updated', key: 'ticket.updated', created_at: 2.hours.ago)
    end
    let!(:deleted_activity) do
      create_activity(trackable: scope_ticket, action: 'deleted', key: 'ticket.deleted', created_at: 1.hour.ago)
    end

    # Scope all assertions to the scope_ticket to avoid interference from other callbacks
    let(:scoped) { Activity.where(trackable: scope_ticket) }

    describe '.recent' do
      it 'orders by created_at desc' do
        expect(scoped.recent.to_a).to eq([deleted_activity, updated_activity, created_activity])
      end
    end

    describe '.for_actor' do
      it 'returns only activities for the given user' do
        other_user = create(:user)
        create(:membership, user: other_user, organisation: organisation)
        other_activity = create_activity(trackable: scope_ticket, actor: other_user)

        expect(scoped.for_actor(user)).to contain_exactly(created_activity, updated_activity, deleted_activity)
        expect(scoped.for_actor(user)).not_to include(other_activity)
      end
    end

    describe '.for_trackable' do
      it 'returns only activities for the given trackable' do
        other_ticket = build(:ticket, project: project, organisation: organisation)
        other_ticket.define_singleton_method(:track_activities?) { false }
        other_ticket.save!
        other_activity = create_activity(trackable: other_ticket)

        expect(Activity.for_trackable(scope_ticket)).to contain_exactly(created_activity, updated_activity, deleted_activity)
        expect(Activity.for_trackable(scope_ticket)).not_to include(other_activity)
      end
    end

    describe '.for_action' do
      it 'filters by action string' do
        expect(scoped.for_action('created')).to contain_exactly(created_activity)
        expect(scoped.for_action('updated')).to contain_exactly(updated_activity)
      end
    end

    describe '.for_key' do
      it 'filters by key string' do
        expect(scoped.for_key('ticket.created')).to contain_exactly(created_activity)
        expect(scoped.for_key('ticket.deleted')).to contain_exactly(deleted_activity)
      end
    end

    describe '.today' do
      it 'returns only activities created today' do
        today_activity = create_activity(trackable: scope_ticket, created_at: Time.current)
        expect(scoped.today).to include(today_activity)
        expect(scoped.today).not_to include(created_activity) # 1.day.ago
      end
    end

    describe '.this_week' do
      include ActiveSupport::Testing::TimeHelpers

      it 'returns activities from the current week' do
        this_week_activity = create_activity(trackable: scope_ticket, created_at: Time.current)
        old_activity = create_activity(trackable: scope_ticket, created_at: 2.weeks.ago)

        expect(scoped.this_week).to include(this_week_activity)
        expect(scoped.this_week).not_to include(old_activity)
      end

      # The example above passed six days out of seven. The scope bound the range with
      # Date#end_of_week, a DATE, which Rails binds as midnight - so the whole last day
      # of the week fell outside, and only a CI run that happened to land on a Sunday
      # ever showed it (2026-09-06, 00:11 UTC). Time is frozen here so the boundary is
      # asserted on every run, not on one seventh of them.
      #
      #   ... Sun 23:59:59.999999 | Mon 00:00:00 ...
      #        ^ last moment in     ^ first moment out
      context 'on the last day of the week' do
        # A Sunday, deep enough into the day that a date-bound range would drop it.
        let(:sunday_evening) { Time.zone.parse('2026-09-06 22:30:00') }

        around { |example| travel_to(sunday_evening) { example.run } }

        it 'still contains an activity created that very day' do
          sunday_activity = create_activity(trackable: scope_ticket, created_at: Time.current)

          expect(scoped.this_week).to include(sunday_activity)
        end

        it 'contains the last moment of the week and excludes the first of the next' do
          last_moment = create_activity(trackable: scope_ticket, created_at: Time.current.end_of_week)
          next_week = create_activity(trackable: scope_ticket, created_at: Time.current.end_of_week + 1.second)

          expect(scoped.this_week).to include(last_moment)
          expect(scoped.this_week).not_to include(next_week)
        end

        it 'contains the first moment of the week and excludes the last of the previous' do
          first_moment = create_activity(trackable: scope_ticket, created_at: Time.current.beginning_of_week)
          previous_week = create_activity(trackable: scope_ticket,
                                          created_at: Time.current.beginning_of_week - 1.second)

          expect(scoped.this_week).to include(first_moment)
          expect(scoped.this_week).not_to include(previous_week)
        end
      end
    end

    describe '.creations' do
      it 'returns only created actions' do
        expect(scoped.creations).to contain_exactly(created_activity)
      end
    end

    describe '.updates' do
      it 'returns only updated actions' do
        expect(scoped.updates).to contain_exactly(updated_activity)
      end
    end

    describe '.deletions' do
      it 'returns only deleted actions' do
        expect(scoped.deletions).to contain_exactly(deleted_activity)
      end
    end
  end

  # ===========================================================================
  # #action_text
  # ===========================================================================
  describe '#action_text' do
    it 'returns translated action text for known keys' do
      activity = create_activity(action: 'created', key: 'ticket.created')
      expect(activity.action_text).to eq(I18n.t('activities.ticket.created'))
    end

    it 'falls back to humanized key when no translation exists' do
      activity = create_activity(action: 'custom', key: 'unknown.custom_action')
      expect(activity.action_text).to eq('Unknown custom action')
    end
  end

  # ===========================================================================
  # #message
  # ===========================================================================
  describe '#message' do
    it 'returns formatted message with actor name' do
      activity = create_activity(parameters: { display_name: 'Test Ticket' })
      expect(activity.message).to include('Anna Schmidt')
    end

    it 'handles nil parameters without crashing' do
      activity = create_activity(parameters: nil)
      expect { activity.message }.not_to raise_error
    end

    it 'handles empty parameters hash' do
      activity = create_activity(parameters: {})
      expect { activity.message }.not_to raise_error
    end

    it 'provides trackable_display_name as default for :display_name' do
      activity = create_activity(parameters: {})
      expect(activity.message).to include(ticket.display_title)
    end

    it 'allows overriding parameters via options' do
      activity = create_activity(parameters: {})
      result = activity.message(display_name: 'Override')
      expect(result).to include('Override')
    end
  end

  # ===========================================================================
  # #trackable_display_name
  # ===========================================================================
  describe '#trackable_display_name' do
    it 'returns "#number title" for Ticket' do
      activity = create_activity(trackable: ticket)
      expect(activity.trackable_display_name).to eq("##{ticket.number} #{ticket.title}")
    end

    it 'returns name for Project' do
      activity = create_activity(trackable: project, key: 'project.created')
      expect(activity.trackable_display_name).to eq(project.name)
    end

    it 'tries :title then :name for other models' do
      doc = create(:document, project: project, organisation: organisation)
      activity = create_activity(trackable: doc, key: 'document.created')
      expected = doc.try(:title) || doc.try(:name) || doc.class.name
      expect(activity.trackable_display_name).to eq(expected)
    end

    it 'falls back to class name when neither title nor name responds' do
      trackable = double('Trackable', class: Activity)
      allow(trackable).to receive(:try).with(:title).and_return(nil)
      allow(trackable).to receive(:try).with(:name).and_return(nil)
      allow(trackable).to receive(:is_a?).and_return(false)

      activity = create_activity
      allow(activity).to receive(:trackable).and_return(trackable)

      expect(activity.trackable_display_name).to eq('Activity')
    end
  end

  # ===========================================================================
  # #icon
  # ===========================================================================
  describe '#icon' do
    {
      'created' => 'plus-circle',
      'updated' => 'pencil',
      'deleted' => 'trash',
      'assigned' => 'person-plus',
      'unassigned' => 'person-dash',
      'status_changed' => 'arrow-right-circle',
      'priority_changed' => 'exclamation-circle',
      'post_added' => 'chat-left-text',
      'moved' => 'arrow-right-square',
      'subscriber_added' => 'bi-person-plus',
      'subscriber_removed' => 'bi-person-dash'
    }.each do |action_name, expected_icon|
      it "returns '#{expected_icon}' for '#{action_name}'" do
        activity = create_activity(action: action_name, key: "ticket.#{action_name}")
        expect(activity.icon).to eq(expected_icon)
      end
    end

    it "returns 'circle' for unknown actions" do
      activity = create_activity(action: 'unknown_action', key: 'ticket.unknown_action')
      expect(activity.icon).to eq('circle')
    end
  end

  # ===========================================================================
  # #css_class
  # ===========================================================================
  describe '#css_class' do
    {
      'created' => 'text-success',
      'deleted' => 'text-danger',
      'assigned' => 'text-info',
      'unassigned' => 'text-info',
      'moved' => 'text-purple-600',
      'subscriber_added' => 'text-success',
      'subscriber_removed' => 'text-danger'
    }.each do |action_name, expected_class|
      it "returns '#{expected_class}' for '#{action_name}'" do
        activity = create_activity(action: action_name, key: "ticket.#{action_name}")
        expect(activity.css_class).to eq(expected_class)
      end
    end

    it "returns 'text-muted' for unknown actions" do
      activity = create_activity(action: 'unknown', key: 'ticket.unknown')
      expect(activity.css_class).to eq('text-muted')
    end

    it "returns 'text-muted' for 'updated'" do
      activity = create_activity(action: 'updated', key: 'ticket.updated')
      expect(activity.css_class).to eq('text-muted')
    end
  end

  # ===========================================================================
  # #has_changes?
  # ===========================================================================
  describe '#has_changes?' do
    it 'returns true when attribute_changes has entries' do
      activity = create_activity(attribute_changes: { 'title' => %w[Old New] })
      expect(activity.has_changes?).to be true
    end

    it 'returns false when attribute_changes is empty hash' do
      activity = create_activity(attribute_changes: {})
      expect(activity.has_changes?).to be false
    end

    it 'returns false when attribute_changes is nil' do
      activity = create_activity(attribute_changes: nil)
      expect(activity.has_changes?).to be false
    end

    # Regression (user report 05.09.2026): a historic activity holding ONLY
    # the updater_id bookkeeping change rendered a details box with a raw
    # "Updater: <uuid>" row. Nothing worth showing means no details toggle.
    it 'returns false when only noise attributes changed' do
      activity = create_activity(attribute_changes: { 'updater_id' => %w[abc def] })
      expect(activity.has_changes?).to be false
    end
  end

  # ===========================================================================
  # #formatted_changes
  # ===========================================================================
  describe '#formatted_changes' do
    # Display names, never the column: "Summary" stood in the project feed
    # while activerecord.attributes.ticket.summary already read
    # "Zusammenfassung" (user brief 10.09.2026).
    it 'names attribute change keys by their display name' do
      activity = create_activity(attribute_changes: {
                                   'summary' => %w[Alt Neu],
                                   'title' => %w[Old New]
                                 })

      formatted = I18n.with_locale(:de) { activity.formatted_changes }
      expect(formatted.keys).to eq(%w[Zusammenfassung Titel])
      expect(formatted['Titel']).to eq(%w[Old New])
    end

    it 'returns empty hash when attribute_changes is nil' do
      activity = create_activity(attribute_changes: nil)
      expect(activity.formatted_changes).to eq({})
    end

    it 'returns empty hash when attribute_changes is empty' do
      activity = create_activity(attribute_changes: {})
      expect(activity.formatted_changes).to eq({})
    end

    it 'drops the updater_id bookkeeping change and keeps the real ones' do
      activity = create_activity(attribute_changes: {
                                   'updater_id' => %w[abc def],
                                   'title' => %w[Old New]
                                 })

      formatted = I18n.with_locale(:de) { activity.formatted_changes }
      expect(formatted.keys).to eq(['Titel'])
      expect(formatted['Titel']).to eq(%w[Old New])
    end
  end

  # ===========================================================================
  # DSGVO-konforme Display-Methoden
  # ===========================================================================
  describe 'GDPR-compliant display methods' do
    let(:assignee) { create(:user, first_name: 'Max', last_name: 'Muster') }

    before do
      create(:membership, user: assignee, organisation: organisation)
    end

    describe '#assignee_display_name' do
      it 'returns full_name for assigned action with secondary' do
        activity = create_activity(action: 'assigned', key: 'ticket.assigned', secondary: assignee)
        expect(activity.assignee_display_name).to eq('Max Muster')
      end

      it 'returns full_name for unassigned action' do
        activity = create_activity(action: 'unassigned', key: 'ticket.unassigned', secondary: assignee)
        expect(activity.assignee_display_name).to eq('Max Muster')
      end

      it 'returns nil for non-assignment actions' do
        activity = create_activity(action: 'created')
        expect(activity.assignee_display_name).to be_nil
      end

      it 'returns translated fallback when secondary is nil (deleted user)' do
        activity = create_activity(action: 'assigned', key: 'ticket.assigned', secondary: nil)
        expect(activity.assignee_display_name).to eq(I18n.t('activities.deleted_user'))
      end
    end

    describe '#assignee_email' do
      it 'returns email for assignment actions' do
        activity = create_activity(action: 'assigned', key: 'ticket.assigned', secondary: assignee)
        expect(activity.assignee_email).to eq(assignee.email)
      end

      it 'returns nil for non-assignment actions' do
        activity = create_activity(action: 'created')
        expect(activity.assignee_email).to be_nil
      end

      it 'returns nil when secondary is nil' do
        activity = create_activity(action: 'assigned', key: 'ticket.assigned', secondary: nil)
        expect(activity.assignee_email).to be_nil
      end
    end

    describe '#subscriber_display_name' do
      it 'returns display_name for subscriber_added' do
        activity = create_activity(action: 'subscriber_added', key: 'ticket.subscriber_added', secondary: assignee)
        expect(activity.subscriber_display_name).to eq(assignee.display_name)
      end

      it 'returns display_name for subscriber_removed' do
        activity = create_activity(action: 'subscriber_removed', key: 'ticket.subscriber_removed', secondary: assignee)
        expect(activity.subscriber_display_name).to eq(assignee.display_name)
      end

      it 'returns nil for non-subscriber actions' do
        activity = create_activity(action: 'created')
        expect(activity.subscriber_display_name).to be_nil
      end

      it 'returns translated fallback when secondary is nil' do
        activity = create_activity(action: 'subscriber_added', key: 'ticket.subscriber_added', secondary: nil)
        expect(activity.subscriber_display_name).to eq(I18n.t('activities.deleted_user'))
      end
    end

    describe '#post_author_display_name' do
      it 'returns author full_name for post_added action' do
        post = create(:post, ticket: ticket, user: user, organisation: organisation)
        activity = create_activity(action: 'post_added', key: 'ticket.post_added', secondary: post)
        expect(activity.post_author_display_name).to eq(user.full_name)
      end

      it 'returns nil for non-post actions' do
        activity = create_activity(action: 'created')
        expect(activity.post_author_display_name).to be_nil
      end

      it 'returns translated fallback when secondary is nil' do
        activity = create_activity(action: 'post_added', key: 'ticket.post_added', secondary: nil)
        expect(activity.post_author_display_name).to eq(I18n.t('activities.deleted_user'))
      end
    end

    describe '#actor_display_name' do
      it 'returns actor full_name' do
        activity = create_activity
        expect(activity.actor_display_name).to eq('Anna Schmidt')
      end

      it 'returns translated fallback when actor is nil' do
        activity = create_activity
        allow(activity).to receive(:actor).and_return(nil)
        expect(activity.actor_display_name).to eq(I18n.t('activities.deleted_user'))
      end
    end
  end

  # ===========================================================================
  # #detailed_message
  # ===========================================================================
  describe '#detailed_message' do
    let(:assignee) { create(:user, first_name: 'Max', last_name: 'Muster') }

    before do
      create(:membership, user: assignee, organisation: organisation)
    end

    context 'when action is assigned' do
      it 'includes actor, assignee, role, and trackable' do
        activity = create_activity(
          action: 'assigned', key: 'ticket.assigned',
          secondary: assignee,
          parameters: { 'user_role' => 'Developer', 'display_name' => ticket.display_title }
        )

        msg = activity.detailed_message
        expect(msg).to include('Anna Schmidt')
        expect(msg).to include('Max Muster')
        expect(msg).to include('Developer')
        expect(msg).to include(ticket.display_title)
      end

      it 'defaults role to Mitglied when not set' do
        activity = create_activity(
          action: 'assigned', key: 'ticket.assigned',
          secondary: assignee, parameters: {}
        )

        expect(activity.detailed_message).to include('Mitglied')
      end

      it 'handles nil parameters' do
        activity = create_activity(
          action: 'assigned', key: 'ticket.assigned',
          secondary: assignee, parameters: nil
        )

        expect { activity.detailed_message }.not_to raise_error
      end
    end

    context 'when action is unassigned' do
      it 'includes actor, assignee, and trackable' do
        activity = create_activity(
          action: 'unassigned', key: 'ticket.unassigned',
          secondary: assignee, parameters: {}
        )

        msg = activity.detailed_message
        expect(msg).to include('Anna Schmidt')
        expect(msg).to include('Max Muster')
        expect(msg).to include(ticket.display_title)
      end
    end

    context 'when action is post_added' do
      it 'includes post excerpt' do
        post = create(:post, ticket: ticket, user: user, organisation: organisation)
        activity = create_activity(
          action: 'post_added', key: 'ticket.post_added',
          secondary: post,
          parameters: { 'post_excerpt' => 'Ein Kommentar...' }
        )

        msg = activity.detailed_message
        expect(msg).to include(user.full_name)
      end
    end

    context 'when action is moved' do
      it 'includes project names' do
        activity = create_activity(
          action: 'moved', key: 'ticket.moved',
          parameters: { 'from_project_name' => 'Project A', 'to_project_name' => 'Project B' }
        )

        msg = activity.detailed_message
        expect(msg).to include('Project A')
        expect(msg).to include('Project B')
      end
    end

    context 'when action is subscriber_added' do
      it 'includes subscriber name' do
        activity = create_activity(
          action: 'subscriber_added', key: 'ticket.subscriber_added',
          secondary: assignee, parameters: {}
        )

        msg = activity.detailed_message
        expect(msg).to include(assignee.display_name)
        expect(msg).to include('Anna Schmidt')
      end
    end

    context 'when action is subscriber_removed' do
      it 'includes subscriber name' do
        activity = create_activity(
          action: 'subscriber_removed', key: 'ticket.subscriber_removed',
          secondary: assignee, parameters: {}
        )

        msg = activity.detailed_message
        expect(msg).to include(assignee.display_name)
      end
    end

    context 'when action is unknown' do
      it 'delegates to #message' do
        activity = create_activity(action: 'status_changed', key: 'ticket.status_changed',
                                   parameters: { 'from_status' => 'Open', 'to_status' => 'Closed' })

        expect(activity.detailed_message).to eq(activity.message)
      end
    end

    context 'when a status_changed activity has incomplete parameters' do
      it 'does not raise and renders placeholder statuses instead of crashing' do
        activity = create_activity(action: 'status_changed', key: 'ticket.status_changed',
                                   parameters: {})

        expect { activity.detailed_message }.not_to raise_error
        expect(activity.detailed_message).to include('—')
        expect(activity.detailed_message).to include('Anna Schmidt')
      end
    end
  end

  describe '#message robustness' do
    it 'falls back gracefully when interpolation args are missing' do
      activity = create_activity(action: 'status_changed', key: 'ticket.status_changed',
                                 parameters: {})

      expect { activity.message }.not_to raise_error
      expect(activity.message).to include('Anna Schmidt')
    end
  end
end
