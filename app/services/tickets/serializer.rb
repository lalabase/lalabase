# frozen_string_literal: true

module Tickets
  # Single source of truth for the external (JSON) shape of a ticket. Shared by
  # Api::V1::TicketsController and the MCP read tools so the two surfaces cannot
  # drift (D4). Post visibility depends on the viewer, hence `current_user`.
  #
  # NOTE: this serializes the ticket DATA only. Web-client concerns (the Pundit
  # `permissions` block, signed attachment URLs) stay in the API controller — the
  # MCP surface neither needs nor should leak them.
  class Serializer
    def initialize(current_user:)
      @current_user = current_user
    end

    def summary(ticket)
      {
        id: ticket.id,
        number: ticket.number,
        title: ticket.title,
        status: ticket.custom_attributes&.dig('status'),
        status_functions: status_functions(ticket),
        ticket_type: ticket.ticket_type,
        parent_id: ticket.parent_id,
        assignees: assignees(ticket),
        creator: { id: ticket.creator_id, name: ticket.creator&.display_name },
        created_at: ticket.created_at.iso8601,
        updated_at: ticket.updated_at.iso8601
      }
    end

    # By name, then id: the database returns them in no fixed order, and the
    # MCP contract and every client diff would flicker. Sorted in Ruby, so a
    # preloaded association stays preloaded.
    def assignees(ticket)
      ticket.assignees.map { |user| { id: user.id, name: user.display_name } }
            .sort_by { |entry| [entry[:name].to_s.downcase, entry[:id].to_s] }
    end

    # What the status means in its project (SystemFunctions::Registry::STATUS_FUNCTIONS),
    # [] for a status the project gives none or does not know. A client reads this instead
    # of a status name, which means something else in every project. One read per project
    # and serializer, however many of its tickets a list holds.
    def status_functions(ticket)
      status = ticket.custom_attributes&.dig('status')
      return [] unless status.is_a?(String)

      preload_status_functions([ticket.project_id])
      @status_functions[ticket.project_id].fetch(status.downcase, [])
    end

    # Reads the status options of these projects in one query, for a list whose
    # tickets come from several projects. Projects already read are not read again.
    def preload_status_functions(project_ids)
      @status_functions ||= {}
      missing = project_ids.uniq - @status_functions.keys
      return if missing.empty?

      found = TicketAttributeDefinition.status_functions_by_project(missing)
      missing.each { |id| @status_functions[id] = found.fetch(id, {}) }
    end

    # posts: false leaves the comments out, for a caller that pages them itself
    # (#posts_page, the MCP get_ticket tool).
    def full(ticket, posts: true)
      head = summary(ticket).merge(
        summary: ticket.summary,
        description_html: ticket.content&.body&.to_html,
        description_text: ticket.content&.body&.to_plain_text,
        custom_attributes: ticket.custom_attributes,
        project: { id: ticket.project_id, name: ticket.project&.name }
      )
      posts ? head.merge(posts: posts(ticket)) : head
    end

    # The ticket's own attachments, each with the text that was pulled out of it at
    # upload time (ExtractPlainTextProcessingService).
    #
    # Its OWN method rather than a key in #full, because the two surfaces want
    # opposite things: the plain HTTP show renders #full and the attachments route
    # builds its own list with signed URLs, so a body of PDF text in there would be
    # payload nobody asked for. The MCP read tool wants exactly that text and can do
    # nothing with a URL it cannot open; the REST ticket view hands it out only on
    # request, in pages of ten (Tickets::Reading, REST R1), uncut.
    #
    # Ordered oldest first, like the posts: the caller bounds the list, and which
    # files survive that bound must not depend on the order the database felt like.
    #
    # `limit` belongs IN the query, not behind it. plain_text_version is a whole PDF's
    # text, nothing caps how many files hang off a ticket or how long any one of those
    # texts is, and a bound applied after the read has already paid for every row it
    # then throws away.
    def attachments(ticket, limit: nil, offset: 0)
      scope = ticket.ticket_documents
                    .includes(ticket_document_file_attachment: :blob)
                    .order(:created_at, :id)
      scope = scope.limit(limit) if limit
      scope = scope.offset(offset) if offset.positive?

      scope.filter_map { |document| attachment(document) }
    end

    # The honest total next to a bounded list, as a COUNT rather than #attachments.size
    # — the whole point of the limit is that the rows beyond it are never read.
    # Counts rows, so a document whose blob went missing (which #attachments drops) is
    # counted here: the file is on the ticket, we just cannot describe it.
    def attachments_total(ticket)
      ticket.ticket_documents.count
    end

    def posts(ticket)
      loaded(readable_posts(ticket)).order(created_at: :asc).map { |post| post_payload(post) }
    end

    # One page of the comments the current user may read, and how many there are.
    # ONE relation yields both: visibility first, then order (created_at, id, so a
    # page boundary is stable), then the page. The total is that relation's COUNT,
    # so it never includes a comment the reader may not see.
    def posts_page(ticket, page:, per_page:, newest: false)
      readable = readable_posts(ticket)
      direction = newest ? :desc : :asc
      entries = loaded(readable).order(created_at: direction, id: direction)
                                .limit(per_page).offset((page - 1) * per_page)
      [entries.map { |post| post_payload(post) }, readable.count]
    end

    # How many comments the current user may read: the same relation's COUNT,
    # for a caller that shows one of them (get_ticket with post_id).
    def readable_posts_count(ticket)
      readable_posts(ticket).count
    end

    # One comment the current user may read, out of the same relation, or nil:
    # a hidden private comment and a missing one read alike.
    def readable_post(ticket, id)
      post = loaded(readable_posts(ticket)).find_by(id: id)
      post && post_payload(post)
    end

    private

    def readable_posts(ticket)
      ticket.posts.readable_by(@current_user, ticket.organisation)
    end

    # Eager-load everything serialized below (author, rich-text body, attachment
    # rows) so a ticket with many posts does not N+1. Shared by the API show
    # action and the MCP get_ticket tool, both of which can return many posts.
    def loaded(scope)
      scope.includes(:user, :post_documents).with_rich_text_content
    end

    def post_payload(post)
      {
        id: post.id,
        author: { id: post.user_id, name: post.user&.display_name },
        body_html: post.content&.body&.to_html,
        body_text: post.plain_text_version,
        is_private: post.is_private?,
        # post_documents, NOT the has_many_attached :attachments on Post: nothing in
        # the app writes that association (every comment attachment arrives through
        # post_document_files), so the old count answered 0 for every comment that
        # had one — and handed that 0 to the model as a fact.
        # .size on the preloaded association — avoids a COUNT(*) per post.
        attachments_count: post.post_documents.size,
        created_at: post.created_at.iso8601,
        updated_at: post.updated_at.iso8601
      }
    end

    def attachment(document)
      blob = document.ticket_document_file&.blob
      return nil if blob.nil?

      raw = document.plain_text_version
      {
        id: document.id,
        filename: blob.filename.to_s,
        content_type: blob.content_type,
        byte_size: blob.byte_size,
        text: raw.presence,
        # The four-word vocabulary (available / unsupported / unavailable / empty)
        # and the ⚠️ about reading the RAW column live with the extractor's
        # allowlist, shared with Tools::GetDocument.
        text_status: ExtractPlainTextProcessingService.text_status(raw, blob.content_type)
      }
    end
  end
end
