# frozen_string_literal: true

# Rows of the inbox about an event ON A PROJECT (a new note, a new member), as the fanout
# writes them: the notification is filed under the project, the activity names the object in
# its secondary, and the payload carries the activity's id, its action and its parameters
# (Notifications::FanoutService#build_payload). Shared by the specs of the lane kinds.
module ProjectEventRows
  # The activity of an event on `project`, inside the tenant of `organisation`.
  def project_event(organisation, project, action, actor:, secondary: nil, parameters: {})
    ActsAsTenant.with_tenant(organisation) do
      create(:activity, trackable: project, organisation: organisation, actor: actor, secondary: secondary,
                        key: "project.#{action}", action: action, parameters: parameters)
    end
  end

  # The notification about that event. activity: false leaves the payload pointing at an
  # activity that does not exist (retention removed it).
  def project_event_row(organisation, project, action, recipient:, actor:, secondary: nil, parameters: {},
                        activity: true, **attributes)
    event = project_event(organisation, project, action, actor: actor, secondary: secondary, parameters: parameters) if activity
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, { recipient: recipient, actor: actor, organisation: organisation, project: project,
                              notifiable: project, event_type: 'project_announcement', channel: 'in_app',
                              state: :delivered,
                              payload: { 'activity_id' => event&.id || SecureRandom.uuid, 'action' => action,
                                         'parameters' => parameters.stringify_keys } }.merge(attributes))
    end
  end
end

RSpec.configure do |config|
  config.include ProjectEventRows, type: :request
  config.include ProjectEventRows, type: :system
  config.include ProjectEventRows, type: :component
end
