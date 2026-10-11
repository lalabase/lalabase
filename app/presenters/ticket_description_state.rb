# frozen_string_literal: true

# View-model for the collapsible ticket description in the detail view.
#
# Decides, per (ticket, viewing user), three things:
#   - whether the description is shown collapsed,
#   - whether the one-time JIT info box should appear,
#   - whether the "description changed" badge is warranted.
#
# All three hang off the viewer's OWN posts on the ticket:
#   - "known ticket" = the viewer has commented at least once (then we may
#     collapse, because they already know the content);
#   - the change badge compares the description's last edit against the
#     viewer's most recent comment — so a description edited after the viewer
#     last engaged is surfaced rather than hidden.
#
# The collapse preference itself is global per user (User::PreferenceStore),
# not per project.
class TicketDescriptionState
  def initialize(ticket:, current_user:)
    @ticket = ticket
    @current_user = current_user
  end

  # Can this description be collapsed at all? It needs a description and a
  # viewer who already knows the ticket (commented on it). The collapse/expand
  # affordances are only rendered when this is true.
  def collapsible?
    description_present? && known?
  end

  # Collapse the description? Only for collapsible tickets, and only unless the
  # user opted into always-full.
  def collapsed?
    collapsible? && preference_store.collapse_known_ticket_descriptions?
  end

  # Show the one-time JIT info box? Only while we are collapsing AND the user
  # has not yet answered the collapse question (info box or settings).
  def show_infobox?
    collapsed? && !preference_store.description_collapse_answered?
  end

  # Warn that the hidden description changed since the user last engaged.
  # Only meaningful while collapsed; needs both a content edit timestamp and a
  # reference comment, and the edit must be strictly newer than that comment.
  def description_changed?
    return false unless collapsed?

    changed_at = content_updated_at
    last_seen = last_own_post_at
    return false if changed_at.nil? || last_seen.nil?

    changed_at > last_seen
  end

  private

  attr_reader :ticket, :current_user

  # The viewer has commented at least once. Counts the user's own posts
  # regardless of privacy (Post has no default scope) — a private comment
  # still means the ticket is familiar.
  def known?
    return false if current_user.nil?

    ticket.posts.where(user_id: current_user.id).exists?
  end

  def description_present?
    ticket.content.present?
  end

  # Last time the description (ActionText body) was persisted. ActionText only
  # saves the rich_text record when the body actually changed, so this is a
  # content-only timestamp — unaffected by status/assignee edits or new posts.
  def content_updated_at
    ticket.rich_text_content&.updated_at
  end

  def last_own_post_at
    return nil if current_user.nil?

    ticket.posts.where(user_id: current_user.id).maximum(:created_at)
  end

  def preference_store
    current_user.preference_store
  end
end
