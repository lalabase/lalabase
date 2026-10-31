# frozen_string_literal: true

# The relations section, the waiting hint and the "Link" modal of a ticket page
# (doc/ticket_relations_plan.md, revision 4, §8). The ids are written here once: the partials
# render them, the controller's streams target them, and a drift between the two would leave a
# stream without a target.
module TicketRelationsHelper
  def ticket_relations_section_id(ticket)
    "ticket-relations-#{ticket.id}"
  end

  def ticket_waiting_hint_id(ticket)
    "ticket-waiting-#{ticket.id}"
  end

  def ticket_relation_modal_id(ticket)
    "ticket-relation-modal-#{ticket.id}"
  end

  # One opening of the modal inside that frame (review of #944). The streams of a save or a
  # refusal target the instance the form was sent from: a closed one has no element left, so
  # a late answer opens nothing again, and a newer one is not touched.
  def ticket_relation_modal_instance_id(ticket, token)
    "#{ticket_relation_modal_id(ticket)}-#{token}"
  end

  # The "..." button of the ticket header: where the focus returns after the modal when the
  # element that opened it was a menu entry or had no id.
  def ticket_more_actions_id(ticket)
    "ticket-more-actions-#{ticket.id}"
  end

  # "+ Verknüpfen" at the end of the section: the modal finds it again by this id after a save,
  # when the section stream has replaced the element that opened it.
  def ticket_relations_add_id(ticket)
    "ticket-relations-add-#{ticket.id}"
  end

  # One read per ticket and response: the hint in the header and the section in the content
  # render from the same object. Memoised on the view like ticket_subtask_counts_cache
  # (TicketsHelper); the view lives for one response.
  def ticket_relation_section(ticket)
    # rubocop:disable Rails/HelperInstanceVariable
    @ticket_relation_sections ||= {}
    @ticket_relation_sections[ticket.id] ||=
      Tickets::RelationSection.for(ticket: ticket, user: current_user, organisation: current_organisation)
    # rubocop:enable Rails/HelperInstanceVariable
  end

  # A link to a related ticket. Within the same project it stays in the ticket frame, the way
  # a sub-task link does. Into another project it leaves the frame (_top): the lane of project
  # A would otherwise show B while the list and the navigation stay on A (plan §8.2, review 5).
  # data-ticket-link: in the inbox pane it leaves in any case (ticket_pane_links_controller).
  def ticket_relation_link(other, from:, **options, &)
    url = organisation_project_tickets_path(current_organisation, other.project, ticket_id: other.id)
    options[:data] = (options[:data] || {}).merge(ticket_link: true)
    options[:data][:turbo_frame] = '_top' if other.project_id != from.project_id
    link_to(url, options, &)
  end

  # The hourglass of a waiting ticket outside its page (plan §8.3, §8.4): the list's "Wartet"
  # cell with the number beside it (count: true, set in the cell's type), the board card and
  # the phone row without.
  # Nothing when the ticket waits on nothing. The number is TicketsHelper#ticket_waiting_count,
  # so a list that registered its page counts it once for every row.
  #
  # It says how many, never which: a blocker may sit in a project the reader cannot see (plan
  # §4), and the ticket page is where the readable ones are named. role="img" makes the label
  # the one thing a screen reader says, number included. Amber like the header hint; the dark
  # theme maps text-amber-700 to its warning token (application.tailwind.css).
  def ticket_waiting_mark(ticket, count: false)
    waiting_on = ticket_waiting_count(ticket)
    return unless waiting_on.positive?

    label = t('views.organisations.tickets.shared.relations.waiting_mark', count: waiting_on)
    tag.span(role: 'img', title: label, aria: { label: label },
             class: ['ticket-waiting-mark text-amber-700', ('inline-flex items-center gap-1 text-sm tabular-nums' if count)]) do
      safe_join([tag.i(class: 'bi bi-hourglass-split', aria: { hidden: true }), (waiting_on.to_s if count)].compact, ' ')
    end
  end
end
