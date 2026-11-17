# frozen_string_literal: true

# Merging and splitting on the people list above the organisations (GET /people):
# create joins the ticked rows into one person, destroy takes a merge apart again. Both
# are the reader's own notes: nothing in an organisation changes, and no organisation
# learns of either.
#
# Runs WITHOUT a tenant and never sets the session's organisation, like the list itself
# (AllPeopleController). Every rule is the actor's: Actors::MergePeople takes an
# organisation only from the reader's active memberships and reads every entry again under
# that organisation's tenant, with the reader's own right there; Actors::SplitPerson finds
# a group only among the reader's own. That is the authorization of both actions; they ask
# no policy of their own, as the list asks none.
#
# Every answer is a redirect back to the list the reader was looking at (its state
# travels as q, org and page), with a notice or the reason. One answer for everything the
# reader cannot name: an unknown entry, one of an organisation that is not theirs or where
# they lack the people right, a malformed id, another person's group, a missing one.
module AllPeople
  class MergesController < ApplicationController
    skip_before_action :load_tenant_from_session

    # A ticked row sends its sources in one value: "<organisation id>/<address>", joined by
    # a comma when the row stands for several organisations already.
    SOURCE_SEPARATOR = ','
    PART_SEPARATOR = '/'

    def create
      result = Actors::MergePeople.call(entries: entries, current_user: current_user)
      return back(alert: result.errors.to_sentence) unless result.success?

      back(notice: t('controllers.people.merge.success'))
    end

    def destroy
      result = Actors::SplitPerson.call(group_id: params[:id].to_s, current_user: current_user)
      return back(alert: result.errors.to_sentence) unless result.success?

      back(notice: t('controllers.people.split.success'))
    end

    private

    # This page stands above the organisations: no assistant, no page context
    # (ApplicationController#assistant_available?).
    def page_above_organisations?
      true
    end

    # { org:, id: } per source of every ticked row. Only a list of texts counts; what
    # cannot be read as a source stays in the list and is refused by the actor like an
    # unknown entry.
    def entries
      rows = params[:rows]
      return [] unless rows.is_a?(Array)

      rows.grep(String).flat_map { |row| row.split(SOURCE_SEPARATOR) }.map do |source|
        organisation_id, id = source.split(PART_SEPARATOR, 2)
        { org: organisation_id, id: id }
      end
    end

    def back(**flash)
      redirect_to all_people_path(list_state), status: :see_other, **flash
    end

    # The list the reader came from: only text counts, a page only as a number.
    def list_state
      state = { q: params[:q], org: params[:org] }.select { |_name, value| value.is_a?(String) && value.present? }
      page = params[:page].to_s
      state[:page] = page if page.match?(/\A[1-9]\d{0,5}\z/) && page != '1'
      state
    end
  end
end
