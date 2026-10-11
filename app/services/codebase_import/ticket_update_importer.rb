# frozen_string_literal: true

module CodebaseImport
  class TicketUpdateImporter
    attr_reader :ticket, :organisation, :default_user, :import_session_id, :import_file, :tag_import_service, :custom_attribute_service

    def initialize(ticket, organisation, default_user, import_session_id: nil, import_file: nil, tag_import_service: nil, custom_attribute_service: nil)
      @ticket = ticket
      @organisation = organisation
      @default_user = default_user
      @import_session_id = import_session_id
      @import_file = import_file
      @tag_import_service = tag_import_service
      @custom_attribute_service = custom_attribute_service
    end

    def import_updates(updates_data)
      updates_data.each_with_index do |update_data, index|
        # Skip the first update if it's marked as initial (used as ticket content)
        next if index == 0 && update_data[:initial]

        import_single_update(update_data)
      rescue StandardError => e
        Rails.logger.error "Error importing ticket update: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        # Continue with next update instead of failing entire ticket
      end
    end

    private

    def import_single_update(update_data)
      update_user = resolve_user_reference(update_data[:user_id]) || default_user
      content = build_update_content(update_data)

      # Apply ticket changes (assignee, status, priority)
      apply_ticket_changes(update_data[:ticket_changes]) if update_data[:ticket_changes].present?

      # Create activities for changes (after applying them)
      create_activities_for_changes(update_data, update_user) if update_data[:ticket_changes].present?

      # Apply tag changes if present and tag_import_service is available
      apply_tag_changes(update_data[:ticket_changes]) if tag_import_service && update_data[:ticket_changes].present?

      return if content.blank?

      # Convert markdown content to ActionText for posts
      action_text_content = MarkdownToActionTextService.convert(content)

      post = ticket.posts.create!(
        user: update_user,
        organisation: organisation,
        content: action_text_content,
        created_at: parse_timestamp(update_data[:created_at]),
        updated_at: parse_timestamp(update_data[:updated_at])
      )

      # Track imported post if session ID is provided
      track_imported_post(post, update_data) if import_session_id
    end

    def build_update_content(update_data)
      # Only return the actual comment now
      # Changes are now tracked as Activities
      update_data[:content]
    end

    def resolve_user_reference(codebase_user_id)
      return nil if codebase_user_id.blank?

      mapping = CodebaseImportMapping.find_by(
        codebase_id: codebase_user_id.to_s,
        entity_type: 'User'
      )

      return User.find_by(id: mapping.local_id) if mapping

      nil
    end

    def track_imported_post(post, update_data)
      ImportedObject.create!(
        organisation: organisation,
        importable: post,
        import_session_id: import_session_id,
        import_source: 'codebase_hq',
        imported_at: Time.current,
        metadata: {
          original_id: update_data[:id],
          ticket_id: ticket.id,
          original_data: update_data,
          import_file_id: import_file&.id,
          import_file_name: import_file&.original_filename
        }
      )
    end

    def parse_timestamp(timestamp_string)
      return Time.current if timestamp_string.blank?

      begin
        Time.parse(timestamp_string)
      rescue StandardError
        Time.current
      end
    end

    def create_activity_without_callbacks(attributes)
      activity = Activity.new(attributes)
      activity.save!
      activity
    rescue StandardError => e
      Rails.logger.error "Failed to create activity: #{e.message}"
      Rails.logger.error "Activity attributes: #{attributes.inspect}"
      raise
    end

    def create_activities_for_changes(update_data, update_user)
      ticket_changes = update_data[:ticket_changes]
      timestamp = parse_timestamp(update_data[:created_at])

      ticket_changes.each do |field, values|
        case field
        when 'assignee-id'
          create_assignee_activities(values, update_user, timestamp, update_data)
        when 'status-id'
          create_status_activity(values, update_user, timestamp, update_data)
        when 'priority-id'
          create_priority_activity(values, update_user, timestamp, update_data)
          # Additional fields can be added here
        end
      end
    end

    def create_assignee_activities(values, actor, timestamp, update_data)
      # Assignee changes can come in various formats
      if values.is_a?(Hash) && values['assignee-id'].is_a?(Array)
        # Format: {"assignee-id"=>["Guido Boyke", "Erika Muster"]}
        # This means: Guido Boyke → Erika Muster
        assignee_names = values['assignee-id']

        if assignee_names.length >= 2
          # From old to new assignment
          old_assignee_name = assignee_names[0]
          new_assignee_name = assignee_names[1]

          old_user = find_user_by_name(old_assignee_name)
          new_user = find_user_by_name(new_assignee_name)

          # Create unassign Activity for old user
          activity1 = create_activity_without_callbacks(
            organisation: organisation,
            actor: actor,
            trackable: ticket,
            secondary: old_user,
            action: 'unassigned',
            key: 'ticket.unassigned',
            parameters: {
              assignee_name: old_assignee_name,
              user_role: old_user ? determine_user_role(old_user) : 'Mitglied'
            },
            created_at: timestamp,
            updated_at: timestamp
          )
          if import_session_id
            track_imported_activity(activity1, {
                                      original_data: values,
                                      update_id: update_data[:id]
                                    })
          end

          # Create assign Activity for new user
          activity2 = create_activity_without_callbacks(
            organisation: organisation,
            actor: actor,
            trackable: ticket,
            secondary: new_user,
            action: 'assigned',
            key: 'ticket.assigned',
            parameters: {
              assignee_name: new_assignee_name,
              user_role: new_user ? determine_user_role(new_user) : 'Mitglied'
            },
            created_at: timestamp,
            updated_at: timestamp
          )
          if import_session_id
            track_imported_activity(activity2, {
                                      original_data: values,
                                      update_id: update_data[:id]
                                    })
          end
        elsif assignee_names.length == 1
          # Only one person = new assignment
          assignee_name = assignee_names[0]
          assignee_user = find_user_by_name(assignee_name)

          activity = create_activity_without_callbacks(
            organisation: organisation,
            actor: actor,
            trackable: ticket,
            secondary: assignee_user,
            action: 'assigned',
            key: 'ticket.assigned',
            parameters: {
              assignee_name: assignee_name,
              user_role: assignee_user ? determine_user_role(assignee_user) : 'Mitglied'
            },
            created_at: timestamp,
            updated_at: timestamp
          )
          if import_session_id
            track_imported_activity(activity, {
                                      original_data: values,
                                      update_id: update_data[:id]
                                    })
          end
        end
      elsif values.is_a?(Array) && values.length == 2
        # Format: ["", "Erika Muster"] or ["Erika Muster", ""]
        old_assignee = values[0].presence
        new_assignee = values[1].presence

        if old_assignee && !new_assignee
          # Unassigned
          assignee_user = find_user_by_name(old_assignee)
          activity = create_activity_without_callbacks(
            organisation: organisation,
            actor: actor,
            trackable: ticket,
            secondary: assignee_user,
            action: 'unassigned',
            key: 'ticket.unassigned',
            parameters: {
              assignee_name: old_assignee,
              user_role: assignee_user ? determine_user_role(assignee_user) : 'Mitglied'
            },
            created_at: timestamp,
            updated_at: timestamp
          )
          track_imported_activity(activity, { original_data: values, update_id: update_data[:id] }) if import_session_id
        elsif !old_assignee && new_assignee
          # Assigned
          assignee_user = find_user_by_name(new_assignee)
          activity = create_activity_without_callbacks(
            organisation: organisation,
            actor: actor,
            trackable: ticket,
            secondary: assignee_user,
            action: 'assigned',
            key: 'ticket.assigned',
            parameters: {
              assignee_name: new_assignee,
              user_role: assignee_user ? determine_user_role(assignee_user) : 'Mitglied'
            },
            created_at: timestamp,
            updated_at: timestamp
          )
          track_imported_activity(activity, { original_data: values, update_id: update_data[:id] }) if import_session_id
        elsif old_assignee && new_assignee && old_assignee != new_assignee
          # Reassigned (unassign old, assign new)
          old_user = find_user_by_name(old_assignee)
          new_user = find_user_by_name(new_assignee)

          # Unassign activity
          activity1 = create_activity_without_callbacks(
            organisation: organisation,
            actor: actor,
            trackable: ticket,
            secondary: old_user,
            action: 'unassigned',
            key: 'ticket.unassigned',
            parameters: {
              assignee_name: old_assignee,
              user_role: old_user ? determine_user_role(old_user) : 'Mitglied'
            },
            created_at: timestamp,
            updated_at: timestamp
          )
          track_imported_activity(activity1, { original_data: values, update_id: update_data[:id] }) if import_session_id

          # Assign activity
          activity2 = create_activity_without_callbacks(
            organisation: organisation,
            actor: actor,
            trackable: ticket,
            secondary: new_user,
            action: 'assigned',
            key: 'ticket.assigned',
            parameters: {
              assignee_name: new_assignee,
              user_role: new_user ? determine_user_role(new_user) : 'Mitglied'
            },
            created_at: timestamp,
            updated_at: timestamp
          )
          track_imported_activity(activity2, { original_data: values, update_id: update_data[:id] }) if import_session_id
        end
      end
    rescue StandardError => e
      Rails.logger.error "Failed to create assignee activities: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end

    def create_status_activity(values, actor, timestamp, update_data)
      return unless values.is_a?(Array) && values.length == 2

      old_status = values[0]
      new_status = values[1]

      Rails.logger.debug "Status change: old='#{old_status}', new='#{new_status}'"

      return if old_status == new_status

      activity = create_activity_without_callbacks(
        organisation: organisation,
        actor: actor,
        trackable: ticket,
        action: 'status_changed',
        key: 'ticket.status_changed',
        parameters: {
          from_status: old_status,
          to_status: new_status
        },
        attribute_changes: {
          'status' => [old_status, new_status]
        },
        created_at: timestamp,
        updated_at: timestamp
      )

      if import_session_id
        track_imported_activity(activity, {
                                  original_data: values,
                                  update_id: update_data[:id]
                                })
      end
    rescue StandardError => e
      Rails.logger.error "Failed to create status activity: #{e.message}"
    end

    def create_priority_activity(values, actor, timestamp, update_data)
      return unless values.is_a?(Array) && values.length == 2

      old_priority = values[0]
      new_priority = values[1]

      return if old_priority == new_priority

      activity = create_activity_without_callbacks(
        organisation: organisation,
        actor: actor,
        trackable: ticket,
        action: 'priority_changed',
        key: 'ticket.priority_changed',
        parameters: {
          from_priority: old_priority,
          to_priority: new_priority
        },
        attribute_changes: {
          'priority' => [old_priority, new_priority]
        },
        created_at: timestamp,
        updated_at: timestamp
      )

      if import_session_id
        track_imported_activity(activity, {
                                  original_data: values,
                                  update_id: update_data[:id]
                                })
      end
    rescue StandardError => e
      Rails.logger.error "Failed to create priority activity: #{e.message}"
    end

    def find_user_by_name(name)
      return nil if name.blank?

      # Try to find the user by their full name
      # First search within the organisation
      user = organisation.users.where("first_name || ' ' || last_name = ?", name).first

      # If not found, search in CodebaseImportMapping
      if user.nil?
        # The user may have been imported as a Codebase user
        mapping = CodebaseImportMapping.joins('JOIN users ON users.id = codebase_import_mappings.local_id')
                                       .where(entity_type: 'User')
                                       .where("users.first_name || ' ' || users.last_name = ?", name)
                                       .first
        user = User.find_by(id: mapping.local_id) if mapping
      end

      user
    end

    def determine_user_role(user)
      # Determine the user's role within the organisation
      membership = user.memberships.find_by(organisation: organisation)
      membership&.role&.title || 'Mitglied'
    end

    def track_imported_activity(activity, metadata = {})
      ImportedObject.create!(
        organisation: organisation,
        importable: activity,
        import_session_id: import_session_id,
        import_source: 'codebase_hq',
        imported_at: Time.current,
        metadata: {
          import_file_id: import_file&.id,
          import_file_name: import_file&.original_filename,
          ticket_id: ticket.id,
          **metadata
        }
      )
    end

    def apply_ticket_changes(ticket_changes)
      return unless ticket_changes.present?

      ticket_changes.each do |field, values|
        case field
        when 'assignee-id'
          apply_assignee_change(values)
        when 'status-id'
          apply_status_change(values)
        when 'priority-id'
          apply_priority_change(values)
        end
      end
    end

    def apply_assignee_change(values)
      # Determine the new assignee
      new_assignee_name = if values.is_a?(Hash) && values['assignee-id'].is_a?(Array)
                            # Format: {"assignee-id"=>["Guido Boyke", "Erika Muster"]}
                            values['assignee-id'].last
                          elsif values.is_a?(Array) && values.length >= 2
                            # Format: ["", "Erika Muster"] or ["Erika Muster", ""]
                            values[1].presence || nil
                          else
                            nil
                          end

      if new_assignee_name.present?
        new_assignee = find_user_by_name(new_assignee_name)
        if new_assignee
          # Remove all current assignees and add the new one
          ticket.assignees = [new_assignee]
          Rails.logger.debug "Updated ticket assignee to: #{new_assignee.email}"
        else
          Rails.logger.warn "Could not find user with name: #{new_assignee_name}"
        end
      else
        # Remove all assignees
        ticket.assignees.clear
        Rails.logger.debug 'Removed all ticket assignees'
      end
    rescue StandardError => e
      Rails.logger.error "Failed to apply assignee change: #{e.message}"
    end

    def apply_status_change(values)
      return unless values.is_a?(Array) && values.length == 2

      new_status = values[1]
      return if new_status.blank?

      # Status is stored as a custom attribute
      ticket.set_custom_attribute('status', new_status)
      ticket.save!
      Rails.logger.debug "Updated ticket status to: #{new_status}"
    rescue StandardError => e
      Rails.logger.error "Failed to apply status change: #{e.message}"
    end

    def apply_priority_change(values)
      return unless values.is_a?(Array) && values.length == 2

      new_priority = values[1]
      return if new_priority.blank?

      # Priority is stored as a custom attribute
      ticket.set_custom_attribute('priority', new_priority)
      ticket.save!
      Rails.logger.debug "Updated ticket priority to: #{new_priority}"
    rescue StandardError => e
      Rails.logger.error "Failed to apply priority change: #{e.message}"
    end

    def apply_tag_changes(ticket_changes)
      return unless ticket_changes.present? && ticket_changes['tags'].present?

      tag_change = ticket_changes['tags']
      Rails.logger.debug "Applying tag changes: #{tag_change.inspect}"

      # Tag changes can be in different formats:
      # - Array with two elements: [old_tags, new_tags] for a change
      # - Array with one element: [new_tags] for an addition
      # - String: direct tag value
      new_tags_string = if tag_change.is_a?(Array)
                          tag_change.last # Take the new value (last element)
                        else
                          tag_change.to_s
                        end

      if new_tags_string.present?
        Rails.logger.debug "Assigning tags to ticket ##{ticket.number}: #{new_tags_string}"
        tag_import_service.assign_tags_to_ticket(ticket, new_tags_string)
      else
        Rails.logger.debug "Clearing tags from ticket ##{ticket.number}"
        ticket.tag_list = []
      end
    rescue StandardError => e
      Rails.logger.error "Failed to apply tag changes: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end
  end
end
