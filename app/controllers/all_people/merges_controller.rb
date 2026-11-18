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
# The card of a merged person takes a merge apart as well: destroy with `source`
# ("<organisation id>:<entry address>") takes that one source out and leaves the rest
# merged. `card` (the address of the open card) travels for the way back, from the card's
# menu and from the merge bar (which layout-toggle hands the card open now, data-lane-keep).
#
# Every answer is a redirect back to the list the reader was looking at (its state
# travels as q, org and page, and the open card), with a notice or the reason. One answer for everything the
# reader cannot name: an unknown entry, one of an organisation that is not theirs or where
# they lack the people right, a malformed id, another person's group, a missing one.
# A failure the actor did not write a text for (in production BaseActor hands on the
# message of an exception, which may quote a statement or a lock) shows one sentence of
# ours instead (#reason).
module AllPeople
  class MergesController < ApplicationController
    skip_before_action :load_tenant_from_session

    # A ticked row sends its sources in one value: "<organisation id>/<address>", joined by
    # a comma when the row stands for several organisations already.
    SOURCE_SEPARATOR = ','
    PART_SEPARATOR = '/'

    def create
      result = Actors::MergePeople.call(entries: entries, current_user: current_user)
      return back(alert: reason(result, Actors::MergePeople::REFUSALS, 'merge')) unless result.success?

      back(notice: t('controllers.people.merge.success'))
    end

    def destroy
      result = Actors::SplitPerson.call(group_id: params[:id].to_s, current_user: current_user, source: one_source)
      return back(alert: reason(result, Actors::SplitPerson::REFUSALS, 'split')) unless result.success?

      back(notice: t(one_source ? 'controllers.people.split.source_success' : 'controllers.people.split.success'))
    end

    private

    # This page stands above the organisations: no assistant, no page context
    # (ApplicationController#assistant_available?).
    def page_above_organisations?
      true
    end

    # The ticked rows, each a list of { org:, id: }, one per source. The rows stay apart:
    # the actor refuses fewer than two ROWS, and one row of a person in two organisations
    # has two sources. Only a list of texts counts; what cannot be read as a source stays
    # in its row and is refused by the actor like an unknown entry.
    def entries
      rows = params[:rows]
      return [] unless rows.is_a?(Array)

      rows.grep(String).map do |row|
        row.split(SOURCE_SEPARATOR).map do |source|
          organisation_id, id = source.split(PART_SEPARATOR, 2)
          { org: organisation_id, id: id }
        end
      end
    end

    # The one source to take out of a merge, nil for the whole merge. A parameter that is
    # there and is no text names no source: the actor refuses it, it never reads it as
    # "the whole merge".
    def one_source
      return unless params.key?(:source)

      source = params[:source]
      source.is_a?(String) ? source : ''
    end

    # The actor's own text for a refusal it names, one sentence of ours for anything else.
    def reason(result, refusals, action)
      refusals.include?(result.code) ? result.errors.to_sentence : t("controllers.people.#{action}.failed")
    end

    def back(**flash)
      redirect_to all_people_path(list_state), status: :see_other, **flash
    end

    # The list the reader came from, and the card that was open: only text counts, a page
    # only as a number.
    def list_state
      state = { q: params[:q], org: params[:org], card: params[:card] }.select { |_name, value| value.is_a?(String) && value.present? }
      page = params[:page].to_s
      state[:page] = page if page.match?(/\A[1-9]\d{0,5}\z/) && page != '1'
      state
    end
  end
end
