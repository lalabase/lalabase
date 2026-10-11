# frozen_string_literal: true

# Specific tracking behavior for tickets
module TicketTrackable
  extend ActiveSupport::Concern

  included do
    include Trackable

    # Callbacks for posts must be defined in the Ticket model
    # since they are applied to has_many :posts
  end

  # GDPR-compliant implementation of activity tracking
  #
  # Why we do not store personal data in activity parameters:
  #
  # 1. Data minimization (Art. 5(1)(c) GDPR)
  #    - We store only the minimally necessary data
  #    - Personal data is only linked via references (secondary association)
  #    - Names, e-mails etc. are NOT duplicated into JSONB fields
  #
  # 2. Right to erasure (Art. 17 GDPR)
  #    - When a user is deleted, activities are retained (audit trail)
  #    - But all personal data is automatically gone (only the reference remains)
  #    - Helper methods then display "Deleted user"
  #
  # 3. Data portability & anonymization (Art. 20 GDPR)
  #    - User data can be anonymized at any time (e.g. name → "ANON USER")
  #    - Activities remain readable with the updated data
  #    - No need to search through and update activities
  #
  # 4. Purpose limitation (Art. 5(1)(b) GDPR)
  #    - Activities serve the audit trail and traceability
  #    - References suffice for that - no copies of personal data needed
  #
  # What we store instead:
  # - References to objects (secondary_id for User/Post)
  # - Non-personal metadata (user_role, display_name of the ticket)
  # - IDs and names of status/priority (for reporting even after deletion)

  # Public callback methods for associations (must be public for Rails to call them)

  # extra_parameters lets callers thread flags into the activity that the
  # notification pipeline reads (e.g. skip_email for onboarding seed
  # assignments) — one creation path instead of a duplicate hand-built one.
  def track_assignee_added(user, extra_parameters = {})
    # GDPR: We store only the user reference (secondary) and the role
    # Name and e-mail are fetched from the reference at runtime
    create_activity(
      action: 'assigned',
      secondary: user,
      parameters: {
        display_name: display_title,
        user_role: user.role_in_organisation(organisation)&.title # role is not personal information
      }.merge(extra_parameters)
    )
  end

  def track_assignee_removed(user, extra_parameters = {})
    # GDPR: Analogous to track_assignee_added
    create_activity(
      action: 'unassigned',
      secondary: user,
      parameters: {
        display_name: display_title,
        user_role: user.role_in_organisation(organisation)&.title
      }.merge(extra_parameters)
    )
  end

  def track_moved(from_project, to_project)
    create_activity(
      action: 'moved',
      parameters: {
        display_name: display_title,
        from_project_name: from_project.name,
        from_project_id: from_project.id,
        to_project_name: to_project.name,
        to_project_id: to_project.id
      }
    )
  end

  def track_post_added(post)
    # GDPR: The post reference is stored, author info is fetched via post.user
    # Only the text excerpt is stored (factual, not personal)
    parameters = { display_name: display_title, has_attachments: post.post_documents.any? }
    # Every reader of the feed, the activities API and a notification card sees the
    # excerpt, so a private comment carries none (Post.readable_by). A comment that
    # turns private later loses it through Posts::ExcerptRedaction.
    parameters[:post_excerpt] = post.content.to_plain_text.truncate(100) if post.public?

    create_activity(action: 'post_added', secondary: post, parameters: parameters)
  end

  def track_subscriber_added(user)
    # GDPR: Analogous to track_assignee_added — only user reference (secondary), no PII
    create_activity(
      action: 'subscriber_added',
      secondary: user,
      parameters: {
        display_name: display_title
      }
    )
  end

  def track_subscriber_removed(user)
    # GDPR: Analogous to track_assignee_removed — only user reference (secondary), no PII
    create_activity(
      action: 'subscriber_removed',
      secondary: user,
      parameters: {
        display_name: display_title
      }
    )
  end

  private

  # Special change handlers for tickets
  def track_specific_changes(changed_attrs)
    # Custom attributes changes (status, priority, etc.)
    if changed_attrs['custom_attributes']
      track_custom_attributes_change(changed_attrs['custom_attributes'])
      changed_attrs.delete('custom_attributes')
    end

    # Title change
    if changed_attrs['title']
      track_title_change(changed_attrs['title'])
      changed_attrs.delete('title')
    end

    # Description change - detected via the rich-text row (Trackable), named
    # like the title change so the row says WHAT was updated (user report
    # 05.09.2026: a bare "Aktualisiert" answers nothing).
    if changed_attrs.key?('content')
      changed_attrs.delete('content')
      create_activity(
        action: 'description_changed',
        parameters: { display_name: display_title }
      )
    end

    # Track the remaining changes generically
    return unless changed_attrs.any?

    create_activity(
      action: 'updated',
      attribute_changes: changed_attrs,
      parameters: {
        display_name: display_title,
        updated_fields: changed_attrs.keys
      }
    )
  end

  def track_custom_attributes_change(custom_attrs_change)
    old_attrs, new_attrs = custom_attrs_change

    # Parse the JSONB changes
    old_attrs = old_attrs.is_a?(String) ? JSON.parse(old_attrs) : old_attrs || {}
    new_attrs = new_attrs.is_a?(String) ? JSON.parse(new_attrs) : new_attrs || {}

    # Check for status change
    if old_attrs['status'] != new_attrs['status']
      create_activity(
        action: 'status_changed',
        attribute_changes: {
          status: [old_attrs['status'], new_attrs['status']]
        },
        parameters: {
          from_status: old_attrs['status'],
          to_status: new_attrs['status'],
          display_name: display_title
        }
      )
    end

    # Check for priority change
    if old_attrs['priority'] != new_attrs['priority']
      create_activity(
        action: 'priority_changed',
        attribute_changes: {
          priority: [old_attrs['priority'], new_attrs['priority']]
        },
        parameters: {
          from_priority: old_attrs['priority'],
          to_priority: new_attrs['priority'],
          display_name: display_title
        }
      )
    end

    # Track other custom attribute changes
    other_changes = {}
    (old_attrs.keys + new_attrs.keys).uniq.each do |key|
      next if %w[status priority].include?(key)

      other_changes[key] = [old_attrs[key], new_attrs[key]] if old_attrs[key] != new_attrs[key]
    end

    return unless other_changes.any?

    create_activity(
      action: 'custom_attributes_changed',
      attribute_changes: other_changes,
      parameters: {
        display_name: display_title,
        changed_attributes: other_changes.keys
      }
    )
  end

  def track_title_change(title_change)
    old_title, new_title = title_change

    create_activity(
      action: 'title_changed',
      attribute_changes: {
        title: title_change
      },
      parameters: {
        from_title: old_title,
        to_title: new_title,
        display_name: display_title
      }
    )
  end

  # Tag tracking must happen via process_tag_list_changes
  # since the Taggable concern has no after_add/after_remove callbacks

  # Override of Trackable

  def activity_parameters_for_create
    {
      display_name: display_title,
      project_name: project.name,
      status: get_custom_attribute('status'),
      priority: get_custom_attribute('priority')
    }
  end

  def activity_parameters_for_update
    {
      display_name: display_title,
      project_name: project.name
    }
  end

  def activity_parameters_for_delete
    {
      display_name: display_title,
      project_name: project.name,
      number: number
    }
  end
end
