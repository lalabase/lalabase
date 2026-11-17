# frozen_string_literal: true

# The people list above the organisations (AllPeopleController).
module AllPeopleHelper
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

  # The list state as the parameters of an address that comes back to this page.
  def all_people_return_state(people)
    all_people_list_state.merge(page: (people.page if people.page > 1)).compact
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
end
