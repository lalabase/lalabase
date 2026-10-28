# frozen_string_literal: true

# The people directory page (Organisations::PeopleController): the wiring of
# its list and lane, and the words of a person's history.
module PeopleHelper
  # The two things a row can open in the lane: a person row, or a member who
  # has no row of their own yet. They exclude each other.
  SELECTION_PARAMS = %w[person_id member_id].freeze
  # The icon of an additional detail that is a link (PersonDetail#href).
  PERSON_DETAIL_ICONS = { 'phone' => 'bi-telephone', 'email' => 'bi-envelope', 'url' => 'bi-link-45deg' }.freeze

  # The page wrapper's data: the lane (layout-toggle, index-page) and the
  # desktop/mobile switch, the same controllers as "Alle Meetings"
  # (meeting_list_page_data), without its filter bar and column picker.
  def people_page_data(viewport_mode:, selected:, form_open:, member: nil)
    detail_frame_id = Organisations::PeopleController::DETAIL_FRAME_ID
    unresolved = people_unresolved_lane_params(selected: selected, member: member, form_open: form_open)
    {
      controller: 'layout-toggle index-page viewport',
      layout_toggle_list_frame_ids_value: [Organisations::PeopleController::LIST_FRAME_ID].to_json,
      layout_toggle_detail_frame_id_value: detail_frame_id,
      layout_toggle_content_selector_value: '.person-content',
      layout_toggle_selected_row_selector_value: '.selected-row[data-people-row]',
      layout_toggle_selection_params_value: SELECTION_PARAMS.to_json,
      layout_toggle_list_filter_params_value: Organisations::PeopleController::LIST_PARAMS.to_json,
      layout_toggle_storage_key_value: 'layoutState:people',
      layout_toggle_unresolved_selection_value: (unresolved.to_json if unresolved.any?),
      viewport_breakpoint_value: MeetingsHelper::LANE_FULL_PAGE_BELOW_PX,
      viewport_current_mode_value: viewport_mode,
      index_page_param_name_value: SELECTION_PARAMS.join(','),
      index_page_frame_id_value: detail_frame_id,
      index_page_content_selector_value: '.person-content',
      index_page_placeholder_id_value: 'person-display-placeholder',
      index_page_placeholder_class_value: 'ticket-placeholder px-4',
      index_page_placeholder_title_value: t('views.organisations.people.index.placeholder_title'),
      index_page_placeholder_body_value: t('views.organisations.people.index.placeholder_body'),
      index_page_selected_row_selector_value: '.selected-row[data-people-row]',
      index_page_skip_if_content_visible_value: 'true',
      index_url: organisation_people_path(current_organisation),
      lane_params: lane_params_json(selection: SELECTION_PARAMS, form: %w[new user_id])
    }.compact
  end

  # Lane parameters of this visit the server did not open (an unknown or
  # unreadable person_id, a form the reader may not open). layout-toggle takes
  # them out of the address, so the page stays the list.
  def people_unresolved_lane_params(selected:, form_open:, member: nil)
    unresolved = {}
    person_id = params[:person_id]
    unresolved['person_id'] = person_id if person_id.is_a?(String) && person_id.present? && selected.nil?
    member_id = params[:member_id]
    unresolved['member_id'] = member_id if member_id.is_a?(String) && member_id.present? && member.nil?
    new_state = params[:new]
    unresolved['new'] = new_state if new_state.is_a?(String) && new_state.present? && !form_open
    user_id = params[:user_id]
    unresolved['user_id'] = user_id if user_id.is_a?(String) && user_id.present? && !form_open
    unresolved
  end

  # The name a row or the lane shows: a member (an ACTIVE member, passed as
  # user) through the viewer's name display setting, a contact as written in
  # the row. A row of a former member is a contact: its own name, never the
  # account's current one (search and order read the row too).
  def person_display_name(person: nil, user: nil)
    user ? viewer_display_name(user) : person.name
  end

  # The linked account of a row while it is an active member of this
  # organisation, else nil (the row is then shown as a contact).
  def person_member_user(person)
    return unless person.user_id

    active = Membership.where(organisation: current_organisation, user_id: person.user_id, active: true).exists?
    person.user if active
  end

  # The link state under the name: [icon, words]. A member, a row whose member
  # left (shown as a contact, without the account's name), or no account.
  def person_link_state(person, member)
    if member
      ['bi-person-check', t('views.organisations.people.show.linked_member', name: viewer_display_name(member))]
    elsif person&.user_id
      ['bi-person-dash', t('views.organisations.people.show.former_member')]
    else
      ['bi-person-dash', t('views.organisations.people.show.no_account')]
    end
  end

  # The member whose account fills (and locks) name and email in the form: the
  # STORED link of a saved row, or the member chosen for a new one. A link the
  # save just refused (taken, not a member) is no member: the form shows the
  # select again so the writer can correct it.
  def person_form_member(person)
    return if person.errors.include?(:user_id) || person.errors.include?(:user)
    return person_member_user(person) unless person.persisted?

    membership = person.stored_membership
    membership.user if membership&.active?
  end

  # Whether the form offers the member select: not while a membership stands
  # behind the stored link, active or deactivated (SavePerson keeps it).
  def person_link_choosable?(person)
    !person.persisted? || person.stored_membership.nil?
  end

  # A member row with none of the details the directory is for yet.
  def person_bare?(person)
    person.nil? ||
      %i[salutation function department phone notes additional_details].all? { |field| person.public_send(field).blank? }
  end

  # The lines of the lane: label, value, and for email and phone the link. An
  # active member's email is the account's (the form locks it). The
  # additional details follow the phone, in their stored order.
  def person_fields(person, member)
    person_fixed_fields(person, member) + person_detail_fields(person)
  end

  # One line per additional detail (PersonDetail): the label, or the name of
  # the kind without one. A phone, an email and an http(s) url are links (a
  # url opens a new tab), a date is formatted for the reader, an address keeps
  # its lines. On a phone a link is a tap target named by its label.
  def person_detail_fields(person)
    details = person&.additional_details
    return [] unless details.is_a?(Array)

    details.map do |entry|
      detail = PersonDetail.new(entry)
      label = detail.label.presence || person_detail_kind_name(detail.kind)
      field = { label: label, value: person_detail_value(detail) }
      href = detail.href
      next field unless href

      field.merge(href: href, icon: PERSON_DETAIL_ICONS[detail.kind], mono: detail.kind == 'phone',
                  action: label, external: detail.kind == 'url')
    end
  end

  def person_detail_kind_name(kind)
    return kind.to_s unless PersonDetail::KINDS.include?(kind)

    t("views.organisations.people.details.kinds.#{kind}")
  end

  # The kinds of the form's select: [name, kind], in PersonDetail's order.
  def person_detail_kind_options
    PersonDetail::KINDS.map { |kind| [person_detail_kind_name(kind), kind] }
  end

  # The value field and the label suggestions of a kind in the form. The same
  # map goes to person_details_controller, which switches a row by it; an
  # unknown kind (a hand-made request shown again) gets a plain text field.
  def person_detail_field(kind)
    kind = PersonDetail::KINDS.include?(kind) ? kind : 'text'
    { input: PersonDetail::INPUT_TYPES.fetch(kind), maxlength: PersonDetail.max_value_length(kind),
      list: ("person-detail-suggestions-#{kind}" if person_detail_suggestions(kind).any?) }
  end

  def person_detail_fields_config
    PersonDetail::KINDS.index_with { |kind| person_detail_field(kind) }
  end

  # The label suggestions of a kind (a datalist each: "Mobil", "Fax", ...).
  def person_detail_suggestions(kind)
    Array(t("views.organisations.people.form.detail_suggestions.#{kind}", default: []))
  end

  # The value of a detail as the lane shows it.
  def person_detail_value(detail)
    date = detail.date
    return l(date, format: :long) if date
    return safe_join(detail.lines, tag.br) if detail.kind == 'address'

    detail.value
  end

  # The fixed fields of the lane, in the order of the form.
  def person_fixed_fields(person, member)
    email = member ? member.email : person&.email
    phone = person&.phone
    [
      ({ label: Person.human_attribute_name(:salutation), value: person.salutation } if person&.salutation.present?),
      ({ label: Person.human_attribute_name(:function), value: person.function } if person&.function.present?),
      ({ label: Person.human_attribute_name(:department), value: person.department } if person&.department.present?),
      ({ label: Person.human_attribute_name(:company), value: person.company } if person&.company.present?),
      ({ label: Person.human_attribute_name(:email), value: email, href: "mailto:#{email}", icon: 'bi-envelope' } if email.present?),
      if phone.present?
        { label: Person.human_attribute_name(:phone), value: phone, href: "tel:#{phone.gsub(/[^\d+]/, '')}",
          icon: 'bi-telephone', mono: true, action: t('views.organisations.people.show.call') }
      end
    ].compact
  end

  # The data of a link that opens the form for a member without a row
  # ("Angaben ergänzen", "Bearbeiten" in the member's lane). Like the "+": the
  # PAGE address names the member too (?new=person&user_id=), so a narrow
  # screen and a reload open the form with the member chosen.
  def add_member_details_link(member)
    new_state = Organisations::PeopleController::NEW_STATE
    {
      href: organisation_people_path(current_organisation, list_state.merge('new' => new_state, 'user_id' => member.id)),
      data: {
        controller: 'lane-link',
        action: 'click->lane-link#click',
        lane_link_url_value: new_organisation_person_path(current_organisation, user_id: member.id),
        lane_link_frame_value: Organisations::PeopleController::DETAIL_FRAME_ID,
        lane_link_set_value: { new: new_state, user_id: member.id }.to_json,
        lane_link_remove_value: SELECTION_PARAMS.to_json
      }
    }
  end

  # Initials for a contact's avatar (no account, no picture).
  def person_initials(name)
    name.to_s.split.first(2).map { |part| part[0] }.join.upcase
  end

  # The name of whoever created or changed a row, only when the reader may see
  # that person on the members page (MembershipPolicy::Scope, the rule the
  # whole directory follows); otherwise "Jemand". The reader always sees
  # themselves.
  def person_actor_name(user)
    return t('views.organisations.people.show.someone') unless user

    visible = user.id == current_user.id || people_visible_member_ids.include?(user.id)
    visible ? viewer_display_name(user) : t('views.organisations.people.show.someone')
  end

  # One line of the history: who did what. An update names the changed fields
  # (never their values, PersonTrackable).
  def person_history_line(activity)
    actor = person_actor_name(activity.actor)
    case activity.action
    when 'created' then t('views.organisations.people.history.created', actor: actor)
    when 'updated'
      fields = activity.attribute_changes.to_h.keys.map { |field| Person.human_attribute_name(field.delete_suffix('_id')) }
      t('views.organisations.people.history.updated', actor: actor, fields: fields.to_sentence)
    else t('views.organisations.people.history.other', actor: actor)
    end
  end

  # The options of the member select: the active members the reader may link
  # (visible on the members page, without a row of their own yet), labelled
  # through the viewer's name display setting. A row whose stored link has a
  # membership behind it gets no select (person_link_choosable?), so no stored
  # member needs an option of its own here (review of PR #64).
  def member_options_for(person)
    taken = Person.where(organisation: current_organisation).linked.where.not(id: person.id).select(:user_id)
    member_ids = policy_scope(Membership).where(organisation: current_organisation, active: true).select(:user_id)
    members = User.where(id: member_ids).where.not(id: taken).to_a
    members.map { |user| [viewer_display_name(user), user.id] }.sort_by { |label, _id| label.downcase }
  end

  # How long ago a last contact was, in calendar days (S2a): heute, gestern,
  # vor n Tagen, Wochen, Monaten, Jahren. Not time_ago_in_words: that counts
  # hours ("etwa 1 Stunde") and calls late yesterday evening "today".
  def last_contact_age(at)
    days = (Time.zone.today - at.in_time_zone.to_date).to_i
    scope = 'views.organisations.people.age'
    return t("#{scope}.today") if days <= 0
    return t("#{scope}.yesterday") if days == 1
    return t("#{scope}.days", count: days) if days < 7
    return t("#{scope}.weeks", count: days / 7) if days < 30
    return t("#{scope}.months", count: days / 30) if days < 365

    t("#{scope}.years", count: days / 365)
  end

  # The words of a last contact (People::Contacts::LastContact): the last
  # meeting with its date (with the year when it is not this year), or the
  # ticket work with its age.
  def last_contact_text(last)
    scope = 'views.organisations.people.last_contact'
    if last.kind == :meeting
      date = last.at.to_date
      t("#{scope}.meeting", title: last.meeting_title,
                            date: l(date, format: date.year == Time.zone.today.year ? :short : :default))
    else
      t("#{scope}.ticket.#{last.action}", number: last.ticket_number, age: last_contact_age(last.at))
    end
  end

  # The last contact and the readable meetings of one person or member in the
  # lane. A member (the account, active) counts their ticket work too; a row
  # of a former member only its meetings.
  def person_contacts(person: nil, member: nil)
    contacts = People::Contacts.new(viewer: current_user, organisation: current_organisation)
    meetings = contacts.meetings_for(person: person, user: member).includes(:project)
    { last: contacts.last_contacts([People::Contacts::Subject.for(person: person, member: member)]).first,
      meetings: meetings }
  end
end
