# frozen_string_literal: true

require 'rails_helper'

# Notification rows draw their actor through Neo::Users::NameComponent in circle
# mode (doc/user_display_name_avatar_plan.md, S2). The component asks
# avatar.attached?, which costs one query per DISTINCT actor unless the scope
# preloads the attachment and its blob — the hazard the component's own comment
# names, and the one both notification scopes walked into when the
# ui-avatars.com helper (a pure string build, no query at all) was replaced.
#
# The bell dropdown is the expensive one: it sits in the layout, so without the
# preload EVERY page in the app pays one attachment query per actor shown in it.
RSpec.describe 'Notification actor avatars are preloaded', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let!(:permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: project, tickets_access: 'read_write')
    end
  end

  # Fixtures live in a method, not a before block: the per-actor setup work (the
  # avatar validation reads the blob, the variant pre-warm enqueues a job) is a
  # loop over records, not a request-scoped N+1, and Prosopite has to be paused
  # around it. A before block runs AFTER the global Prosopite.scan, so pausing
  # there would come too late.
  #
  # Three DISTINCT actors, one ticket each: Rails hands the same User instance to
  # every notification sharing an actor, and the inbox groups by notifiable, so a
  # single actor or a single ticket would leave the per-actor query nothing to
  # repeat over and the example would pass without the preload.
  def seed_notifications_with_avatars
    Prosopite.pause
    ActsAsTenant.with_tenant(organisation) do
      3.times do
        actor = create(:user)
        create(:membership, user: actor, organisation: organisation, role: role, active: true)
        actor.avatar.attach(io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
                            filename: 'avatar.png', content_type: 'image/png')
        actor.save!
        create(:notification, recipient: user, actor: actor, organisation: organisation,
                              project: project, notifiable: create(:ticket, project: project),
                              state: :delivered)
      end
    end
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Prosopite.resume
  end

  def attachment_queries_during
    seen = []
    subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      seen << payload[:sql] if payload[:sql]&.include?('active_storage_attachments')
    end
    yield
    seen
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  # Counted, not sampled: with the preload the page issues the two batched loads
  # (attachments IN (...), then their blobs) and nothing per actor. Take the
  # dropdown's preload away and this is 3 — one LIMIT 1 lookup per actor, on
  # every page that renders the layout.
  it 'pays no per-actor attachment query for the bell dropdown' do
    seed_notifications_with_avatars

    queries = attachment_queries_during do
      get organisation_notifications_path(organisation, state_filters: %w[unread delivered])
    end

    expect(response).to have_http_status(:ok)
    expect(response.body.scan(%r{rails/active_storage}).size).to be >= 3
    expect(queries.size).to be <= 2
  end

  # The inbox list scope carries its own preload, and this page is not its only
  # reader (the turbo refresh renders notifications/_list, which renders the row
  # partial with the circle). Assert the mechanism directly rather than through
  # one route's markup.
  it 'hands for_notification_center actors whose attachment and blob are loaded' do
    seed_notifications_with_avatars

    loaded = ActsAsTenant.with_tenant(organisation) do
      Notification.where(recipient: user).for_notification_center.to_a
    end

    expect(loaded.size).to eq(3)
    expect(loaded.map { |n| n.actor.association(:avatar_attachment).loaded? }).to all(be(true))
    expect(loaded.map { |n| n.actor.avatar_attachment.association(:blob).loaded? }).to all(be(true))
  end
end
