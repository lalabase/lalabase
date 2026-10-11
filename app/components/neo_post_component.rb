# frozen_string_literal: true

class NeoPostComponent < ViewComponent::Base
  include ActionView::Helpers::DateHelper
  include ActionView::Helpers::TextHelper

  # show_author: false collapses the head for a follow-up comment by the SAME
  # person (Slack's grouping rule, user mockup 05.09.2026) — the timeline list
  # decides adjacency, this component only renders the consequence.
  def initialize(
    post:,
    current_user:,
    current_organisation:,
    show_edit_button: true,
    turbo_frame: true,
    show_author: true
  )
    @post = post
    @current_user = current_user
    @current_organisation = current_organisation
    @show_edit_button = show_edit_button && can_edit?
    @turbo_frame = turbo_frame
    @show_author = show_author
  end

  # Cache key for fragment caching
  def cache_key_with_version
    [
      'neo_post',
      'v6',
      @post.cache_key_with_version,
      @current_user.id,
      @show_edit_button ? 'edit' : 'noedit',
      content_digest,
      reactions_digest
    ].join('/')
  end

  private

  attr_reader :post, :current_user, :current_organisation

  def can_edit?
    PostPolicy.new(current_user, post).update?
  end

  def can_react?
    PostPolicy.new(current_user, post).react?
  end

  def reactions
    @reactions ||= if post.association(:post_reactions).loaded?
                     post.post_reactions.to_a
                   else
                     post.post_reactions.includes(:user).to_a
                   end
  end

  # The row time comes from the timeline seam (TimelineHelper), not from the
  # per-area date preference: the day header above this row already carries
  # the date. See the comment on TimelineHelper.
  def row_time
    helpers.timeline_row_time(post)
  end

  # "Bearbeitet ist keine Zeile" (designer round 05.09.2026): an edit shows
  # as a quiet marker in the comment's head, the exact moment in the tooltip.
  # ActionText touches the post on a content edit; the one-minute grace
  # swallows same-request bookkeeping touches (attachments, rich text
  # creation) without hiding a real edit for long.
  def edited?
    post.updated_at > post.created_at + 1.minute
  end

  def edited_tooltip
    I18n.l(post.updated_at, format: :long)
  end

  def formatted_content
    # Use Rails' built-in rich text rendering if available
    if post.respond_to?(:content) && post.content.present?
      post.content
    else
      simple_format(post.body)
    end
  end

  def is_private?
    post.respond_to?(:private?) && post.private?
  end

  def has_attachments?
    post.respond_to?(:post_documents) && post.post_documents.present?
  end

  def attachment_count
    return 0 unless has_attachments?

    post.post_documents.count
  end

  def attachments
    return [] unless has_attachments?

    post.post_documents.includes(:post_document_file_attachment)
  end

  def edit_path
    Rails.application.routes.url_helpers.edit_organisation_project_ticket_post_path(
      current_organisation,
      post.ticket.project,
      post.ticket,
      post
    )
  end

  def post_frame_id
    "post_#{post.id}"
  end

  def content_digest
    Digest::MD5.hexdigest(formatted_content.to_s)[0, 8]
  end

  # Reactions deliberately do not touch the post/ticket. They still belong in
  # the optional shared post fragment cache, including removal of a non-latest
  # reaction, so the digest uses every reaction rather than max(updated_at).
  def reactions_digest
    Digest::MD5.hexdigest(
      reactions.map { |reaction| "#{reaction.id}:#{reaction.updated_at.to_f}" }.sort.join('|')
    )[0, 8]
  end

  def hover_classes
    ''
  end

  def base_classes
    # T4 quiet thread: no card chrome at all - the day groups carry the
    # structure now.
    #
    # The lime ownership edge went on 05.09.2026, and with it the -ml-4/pl-4
    # that existed only to make room for it. It was introduced when T4 removed
    # the card chrome AND the circle mode had dropped the author name, so it
    # was the only answer to "whose comment is this". The mark answers that,
    # and "which one is mine" is not a question a reader actually asks - they
    # know what they wrote. The mark column now defines the left edge, and the
    # activity rows indent onto the same one.
    #
    # pr-10 went with the absolutely positioned pencil: it sits in the meta
    # line now, so nothing has to be kept clear at the right edge.
    #
    # py-3 went with the 05.09.2026 mockup: block spacing lives on the
    # timeline list's wrappers now (6px inside a same-person block, 20px
    # between blocks), and a component padding would add to both.
    'post-card relative'
  end
end
