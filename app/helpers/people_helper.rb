# frozen_string_literal: true

# The people directory page (Organisations::PeopleController): the wiring of
# its list and lane, and the words of a person's history.
module PeopleHelper
  # The page wrapper's data: the lane (layout-toggle, index-page) and the
  # desktop/mobile switch, the same controllers as "Alle Meetings"
  # (meeting_list_page_data), without its filter bar and column picker.
  def people_page_data(viewport_mode:, selected:, form_open:)
    detail_frame_id = Organisations::PeopleController::DETAIL_FRAME_ID
    unresolved = people_unresolved_lane_params(selected: selected, form_open: form_open)
    {
      controller: 'layout-toggle index-page viewport',
      layout_toggle_list_frame_ids_value: [Organisations::PeopleController::LIST_FRAME_ID].to_json,
      layout_toggle_detail_frame_id_value: detail_frame_id,
      layout_toggle_content_selector_value: '.person-content',
      layout_toggle_selected_row_selector_value: '.selected-row[data-person-id]',
      layout_toggle_selection_params_value: %w[person_id].to_json,
      layout_toggle_list_filter_params_value: Organisations::PeopleController::LIST_PARAMS.to_json,
      layout_toggle_storage_key_value: 'layoutState:people',
      layout_toggle_unresolved_selection_value: (unresolved.to_json if unresolved.any?),
      viewport_breakpoint_value: MeetingsHelper::LANE_FULL_PAGE_BELOW_PX,
      viewport_current_mode_value: viewport_mode,
      index_page_param_name_value: 'person_id',
      index_page_frame_id_value: detail_frame_id,
      index_page_content_selector_value: '.person-content',
      index_page_placeholder_id_value: 'person-display-placeholder',
      index_page_placeholder_class_value: 'ticket-placeholder px-4',
      index_page_placeholder_title_value: t('views.organisations.people.index.placeholder_title'),
      index_page_placeholder_body_value: t('views.organisations.people.index.placeholder_body'),
      index_page_selected_row_selector_value: '.selected-row[data-person-id]',
      index_page_skip_if_content_visible_value: 'true',
      index_url: organisation_people_path(current_organisation),
      lane_params: lane_params_json(selection: %w[person_id], form: %w[new])
    }.compact
  end

  # Lane parameters of this visit the server did not open (an unknown or
  # unreadable person_id, a form the reader may not open). layout-toggle takes
  # them out of the address, so the page stays the list.
  def people_unresolved_lane_params(selected:, form_open:)
    unresolved = {}
    person_id = params[:person_id]
    unresolved['person_id'] = person_id if person_id.is_a?(String) && person_id.present? && selected.nil?
    new_state = params[:new]
    unresolved['new'] = new_state if new_state.is_a?(String) && new_state.present? && !form_open
    unresolved
  end

  # The name a row or the lane shows: a member through the viewer's name
  # display setting, a contact as written in the row.
  def person_display_name(person: nil, user: nil)
    user ||= person&.user
    user ? viewer_display_name(user) : person.name
  end

  # Initials for a contact's avatar (no account, no picture).
  def person_initials(name)
    name.to_s.split.first(2).map { |part| part[0] }.join.upcase
  end

  # One line of the history: who did what. An update names the changed fields
  # (never their values, PersonTrackable).
  def person_history_line(activity)
    actor = viewer_display_name(activity.actor)
    case activity.action
    when 'created' then t('views.organisations.people.history.created', actor: actor)
    when 'updated'
      fields = activity.attribute_changes.to_h.keys.map { |field| Person.human_attribute_name(field.delete_suffix('_id')) }
      t('views.organisations.people.history.updated', actor: actor, fields: fields.to_sentence)
    else t('views.organisations.people.history.other', actor: actor)
    end
  end

  # The active members the reader may link a row to: visible on the members
  # page and without a row of their own yet. The row's current member always
  # stays an option, also once deactivated: without it the select shows "no
  # member", and every save of the form would drop the link (review round 1).
  def linkable_members_for(person)
    taken = Person.where(organisation: current_organisation).linked.where.not(id: person.id).select(:user_id)
    member_ids = policy_scope(Membership).where(organisation: current_organisation, active: true).select(:user_id)
    members = User.where(id: member_ids).where.not(id: taken).to_a
    members |= [person.user] if person.user
    members.sort_by { |user| viewer_display_name(user).downcase }
  end
end
