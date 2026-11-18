# frozen_string_literal: true

# The people list above the organisations and the card in its lane (AllPeopleController).
module AllPeopleHelper
  # The "···" button of an open card: where a takeover dialog of any of its contacts
  # returns the focus (person_takeover_modal_controller).
  CARD_MORE_ACTIONS_ID = 'all-people-card-more-actions'

  # The list state an address of the page carries: the search and the organisation it
  # narrows to. Only text counts; a list or a hash in their place is no state.
  def all_people_list_state
    { q: params[:q], org: params[:org] }.select { |_name, value| value.is_a?(String) && value.present? }
  end

  # The address of a page of the list, the first one without a number.
  def all_people_page_path(page)
    all_people_path(all_people_list_state.merge(page: (page if page > 1)).compact)
  end

  # Where a source leads: its organisation's people page with the person open in the lane.
  # The organisation is part of the path, never a parameter named organisation_id.
  def all_people_source_path(source)
    organisation_people_path(source.organisation_id, source.lane)
  end

  # What the tick of a row sends to the merge: every source of the row as
  # "<organisation id>/<address>", joined by a comma (AllPeople::MergesController reads it).
  # A row that stands for several organisations already is merged as all of them.
  def all_people_row_value(row)
    row.sources.map { |source| "#{source.organisation_id}/#{source.fields[:id]}" }.join(',')
  end

  # The list state as the parameters of an address that comes back to this page. A card
  # frame has no list result: it carries the page its request named instead.
  def all_people_return_state(people = nil)
    page = (people ? people.page : params[:page]).to_s
    all_people_list_state.merge(page: (page if page.match?(/\A[1-9]\d{0,5}\z/) && page != '1')).compact
  end

  # Function and company of a row, as the line under a name on an organisation's page.
  def all_people_role(row)
    [row.function, row.company].compact_blank.join(' · ')
  end

  # The age of a row's last contact and its date for the tooltip, nil without one.
  def all_people_last_contact(row)
    return unless row.last_contact

    on = Date.iso8601(row.last_contact[:on])
    { age: last_contact_age(on), date: person_short_date(on) }
  end

  # The page wrapper's data: the lane (layout-toggle, index-page, the controllers of the
  # people page of one organisation) beside the merge of the ticked rows. The address
  # carries the open card as ?card=; the search reloads the list frame and layout-toggle
  # writes the list state into the address beside it.
  def all_people_page_data(card:, people:)
    frame_id = AllPeopleController::CARD_FRAME_ID
    unresolved = all_people_unresolved_lane_params(card)
    renamed = all_people_renamed_lane_params(card, people)
    {
      controller: 'layout-toggle index-page all-people-merge',
      layout_toggle_list_frame_ids_value: [AllPeopleController::LIST_FRAME_ID].to_json,
      layout_toggle_detail_frame_id_value: frame_id,
      layout_toggle_content_selector_value: '.all-people-card',
      layout_toggle_selected_row_selector_value: '.selected-row[data-all-people-row]',
      layout_toggle_selection_params_value: [AllPeopleController::CARD_PARAM].to_json,
      layout_toggle_list_filter_params_value: %w[q org page].to_json,
      layout_toggle_storage_key_value: 'layoutState:all_people',
      layout_toggle_unresolved_selection_value: (unresolved.to_json if unresolved.any?),
      layout_toggle_renamed_selection_value: (renamed.to_json if renamed.any?),
      index_page_param_name_value: AllPeopleController::CARD_PARAM,
      index_page_frame_id_value: frame_id,
      index_page_content_selector_value: '.all-people-card',
      index_page_placeholder_id_value: 'all-people-card-placeholder',
      index_page_placeholder_class_value: 'ticket-placeholder px-4',
      index_page_placeholder_title_value: t('views.all_people.card.placeholder_title'),
      index_page_placeholder_body_value: t('views.all_people.card.placeholder_body'),
      index_page_selected_row_selector_value: '.selected-row[data-all-people-row]',
      index_page_skip_if_content_visible_value: 'true',
      index_url: all_people_path,
      lane_params: lane_params_json(selection: [AllPeopleController::CARD_PARAM], preview: [AllPeopleController::EDITING_PARAM])
    }.compact
  end

  # The lane state of this visit that opened no card (an address that names nobody the
  # viewer can see). layout-toggle takes it out of the address: the page stays the list.
  def all_people_unresolved_lane_params(card)
    address = params[AllPeopleController::CARD_PARAM]
    return {} if card || !address.is_a?(String) || address.blank?

    { AllPeopleController::CARD_PARAM => address, AllPeopleController::EDITING_PARAM => params[AllPeopleController::EDITING_PARAM] }
      .select { |_name, value| value.is_a?(String) && value.present? }
  end

  # The open card named by another of the person's sources than the one its row carries
  # (an old link, an organisation's name that changed the order, a list narrowed to one
  # organisation): { card: [as named, the row's] }, and layout-toggle writes the row's into
  # the address. A list the search draws again knows no card, so its rows carry their own
  # address only; without this the mark went and a click on the row opened the card again
  # instead of closing it. Empty when they agree or when no row of this page is open.
  def all_people_renamed_lane_params(card, people)
    named = params[AllPeopleController::CARD_PARAM]
    return {} unless card && people && named.is_a?(String)

    row = people.rows.find { |one| all_people_row_open?(one, card) }
    address = all_people_row_address(row) if row
    address && address != named ? { AllPeopleController::CARD_PARAM => [named, address] } : {}
  end

  # The address of a row's card: its first source, "<organisation id>:<entry address>".
  def all_people_row_address(row)
    source = row.sources.first
    People::MergedCard.address_of(source.organisation_id, source.fields[:id])
  end

  # Whether the open card is this row's: any source of the row is one of the card's.
  def all_people_row_open?(row, card)
    return false unless card

    row.sources.any? do |source|
      card.sources.any? { |one| one.organisation_id == source.organisation_id && one.address == source.fields[:id] }
    end
  end

  # What makes a row the opener of its card (list-row): the lane's own address in the
  # lane's frame. A row answers to its own address only, the one it carries on every
  # draw of the list; an address that names the open person by another source is
  # renamed to it (all_people_renamed_lane_params).
  def all_people_row_data(row)
    address = all_people_row_address(row)
    {
      controller: 'list-row',
      action: 'click->list-row#click keydown.enter->list-row#click keydown.space->list-row#click',
      list_row_url_value: all_people_path(AllPeopleController::CARD_PARAM => address),
      list_row_id_value: address,
      list_row_param_value: AllPeopleController::CARD_PARAM,
      list_row_params_value: [AllPeopleController::CARD_PARAM].to_json,
      list_row_frame_value: AllPeopleController::CARD_FRAME_ID
    }
  end

  # The address of a card in the lane, with "Bearbeiten" on or off.
  def all_people_card_path(card, editing: false)
    all_people_path({ AllPeopleController::CARD_PARAM => card.address, AllPeopleController::EDITING_PARAM => (1 if editing) }.compact)
  end

  # Where a pencil leads: the people page of that organisation with the form open in its
  # lane, in the page's own words (?edit=, or ?new=person&user_id= for a member without a
  # row). A visit of that page: the rights, the form and the save are that organisation's.
  # edit: what the form edits (People::MergedCard::ValueSource#edit).
  def all_people_edit_path(organisation_id, edit)
    state = if edit[:person_id]
              { PeopleHelper::EDIT_PARAM => edit[:person_id] }
            else
              new_param, user_param = PeopleHelper::FORM_PARAMS
              { new_param => Organisations::PeopleController::NEW_STATE, user_param => edit.fetch(:member_id) }
            end
    organisation_people_path(organisation_id, state)
  end

  # The label of a card's field: the attribute's name, or the label of a detail as written.
  def all_people_field_label(field)
    field.label || Person.human_attribute_name(field.key)
  end

  # A value as the card shows it: an email and a phone number are links, as on the people
  # page of an organisation; everything else is the text.
  def all_people_card_value(field, text)
    href = case field.key
           when :email then "mailto:#{text}"
           when :phone then PersonDetail.new('kind' => 'phone', 'value' => text).href
           end
    href ? link_to(text, href, class: 'people-fields__link') : text
  end

  # The newest last contact of a card: its age, its date for the tooltip and where it was.
  def all_people_card_last_contact(card)
    return unless card.last_contact

    on = Date.iso8601(card.last_contact[:on])
    { age: last_contact_age(on), date: person_short_date(on), organisation: card.last_contact[:organisation_name] }
  end
end
