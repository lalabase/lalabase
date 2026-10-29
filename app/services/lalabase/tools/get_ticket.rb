# frozen_string_literal: true

module Lalabase
  module Tools
    # Fetches a single ticket as JSON (head + description + discussion posts),
    # using Tickets::Serializer#full so the shape cannot drift from the HTTP API
    # (D4). Record-mode (D7): the tool MUST authorize the individual ticket via
    # Base.authorize!(:show?) — the ToolCall's tripwire raises if it doesn't.
    #
    # Two addresses, one payload: the UUID and the ticket NUMBER users see in the
    # app ("#187"). The number is unique per project only, so the project-scoped
    # query is not merely defense in depth here — it is what decides which of the
    # many "#1" in an organisation is meant.
    #
    # Attachments travel with their TEXT, not with a link. This is the only place
    # the model can learn what is in a file hanging off the ticket: the system prompt
    # names a referenced ticket but never its content (Bezugs-Sammlung E5), so a
    # question about the attached PDF is answered from this payload or not at all.
    # A `text_status` per file says whether that text exists, is missing, or was
    # never extractable — silence would be answered with a guess.
    #
    # Caps (D9, over-fetching / DoS): long bodies are truncated, the posts list is
    # bounded, and so are the attachments in both directions (how many, and how much
    # text each). Signed attachment download URLs are deliberately NOT included (the
    # serializer omits them); use the HTTP API when a real download URL is needed.
    #
    # Options and pages come from Tickets::Reading, shared with the REST ticket
    # view (cli_rest_plan D5); only the caps, full_text, post_id and the
    # citations are this tool's own.
    class GetTicket < Base
      MAX_POSTS = Tickets::Reading::MAX_POSTS
      MAX_BODY_CHARS = 8_000
      # MCP keeps the terminal client's full-text allowance (S1 c). The assistant
      # gets a smaller prefix for full_text and post_id, selected by its chat
      # context, never by model arguments. Each HTML/plain-text field has its own
      # allowance; Base.cap_text adds the truncation marker outside that allowance.
      MAX_FULL_TEXT_CHARS = 100_000
      MAX_ASSISTANT_FULL_TEXT_CHARS = 16_000
      MAX_PAGE = Tickets::Reading::MAX_PAGE
      POST_ORDERS = Tickets::Reading::POST_ORDERS

      # The paging arguments (Tickets::Reading.options) plus this tool's own
      # full_text and post_id, parsed once, refused when unusable
      # (Notifications::InboxQuery's rule: no silent default for a value that
      # cannot be read).
      Options = Struct.new(:paging, :full_text, :post_id, keyword_init: true)

      # Attachments are bounded twice: how MANY files answer, and how much text each
      # one contributes.
      #
      # Ten matches the reference collection's own ceiling (Assistant::
      # ReferenceRegistry::MAX_REFERENCES) — a thread may point at ten tickets, and
      # ten files per ticket is already far past what a question is about.
      #
      # The per-file cap is HALF the body cap on purpose: an attachment is context
      # for the ticket, not the ticket. Ten files contribute up to 40k source
      # characters, plus markers and JSON. This does not guarantee room inside
      # Runner::DEFAULT_MAX_TOOL_RESULT_CHARS: ordinary comment pages, uncapped
      # metadata and escaping can still take a whole result past that budget.
      MAX_ATTACHMENTS = Tickets::Reading::MAX_ATTACHMENTS
      MAX_ATTACHMENT_TEXT_CHARS = 4_000

      # Bounds the candidate list of an ambiguous number. Within one project a
      # number matches at most one row, so this only ever bites once the scope
      # spans projects (§9.2).
      MAX_CANDIDATES = 10

      def self.authorization_mode
        :record
      end

      # Authorizes per record against context.actor — declared so the Runner's
      # fail-closed bar refuses the call when no user is in the context.
      def self.requires_actor?
        true
      end

      def self.tool_name
        'get_ticket'
      end

      def self.description
        'Fetches a single ticket as JSON: head fields, description, custom ' \
          'attributes and discussion posts (oldest first). Address the ticket ' \
          'either by ticket_id (its UUID) or by number, the "#187" users see in ' \
          'the app; a number is unique within one project only. ticket_id wins ' \
          'when both are given. Authorized per-record against the token owner. ' \
          'The ticket\'s attachments come with the text extracted from each file, ' \
          'so a question about an attached PDF is answered from here; text_status ' \
          'says whether a file has readable text ("available"), was read and holds ' \
          'none, such as a scanned PDF ("empty"), has not been read out yet or the ' \
          'reading failed, so the same file may answer later ("unavailable"), or is ' \
          'a type we never read text from ("unsupported"). ' \
          'status_functions says what the status means in its project (is_backlog, is_new, ' \
          'is_open, is_in_progress, is_completed, is_closed), [] when the project gave it none. ' \
          'Long bodies are truncated, the posts and attachment lists are capped, ' \
          'and attachment download URLs are not included.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            ticket_id: { type: 'string',
                         description: 'UUID of the ticket to fetch. Wins over number if both are given.' },
            # Declared as a plain string rather than an ['integer', 'string'] union:
            # this schema reaches Gemini verbatim (GoogleVertexProvider#gemini_
            # function_declaration), and its OpenAPI subset takes one type per
            # property. A model that sends the bare integer anyway loses nothing —
            # the parse is tolerant.
            number: { type: 'string',
                      description: 'Ticket number as shown in the app, e.g. "187" or "#187". ' \
                                   'Unique within one project.' },
            posts_page: { type: 'integer', description: 'Page of comments, 1-based (default 1).' },
            posts_per_page: { type: 'integer', description: "Comments per page (default and max #{MAX_POSTS})." },
            posts_order: { type: 'string', enum: POST_ORDERS,
                           description: 'oldest (default) or newest first.' },
            attachments_page: { type: 'integer',
                                description: "Page of attachments, 1-based, #{MAX_ATTACHMENTS} per page." },
            full_text: { type: 'boolean',
                         description: "The whole description, up to #{MAX_FULL_TEXT_CHARS} characters." },
            post_id: { type: 'string',
                       description: 'UUID of one comment of this ticket: only that comment, whole ' \
                                    "(up to #{MAX_FULL_TEXT_CHARS} characters)." }
          }.merge(PROJECT_FILTER_SCHEMA),
          # Neither address is required on its own, but one of them must be there.
          # That rule stays in the tool rather than in an anyOf: the MCP SDK
          # validates arguments against this schema and three LLM providers receive
          # it verbatim, so the flat, widest-compatible form plus an explicit tool
          # error is the safer contract. Dropping the old required: ['ticket_id']
          # is additive — a client that keeps sending a UUID is unaffected.
          required: []
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'project context missing') if context.project.nil? && context.scope.nil?

        args = symbolized(args)
        options = parse_options(args)
        # S3a T5: the project filter disambiguates a number BEFORE the lookup --
        # "#187 in Nordlicht" is the most natural way to resolve exactly the
        # ambiguity this tool otherwise answers with a candidate list.
        chosen = resolve_project_filter(args, context, area: :tickets)
        return chosen if chosen.is_a?(Result)

        result = dispatch(args, context, options, only_project_id: chosen&.id)
        # L7 (S3a T3): every org-wide outcome — hit, candidates, no match — wears
        # its reach. Set centrally so no branch can forget it.
        result.coverage ||= coverage_for(context, area: :tickets, only_project: chosen)
        result
      rescue Tickets::Reading::InvalidOption => e
        Result.invalid_input(e.message)
      end

      def self.dispatch(args, context, options, only_project_id: nil)
        ticket_id = args[:ticket_id].to_s.strip
        # ticket_id wins: it is the exact address, the number is the human one.
        return by_id(ticket_id, context, options, only_project_id) if ticket_id.present?

        raw_number = args[:number].to_s.strip
        return by_number(raw_number, context, options, only_project_id) if raw_number.present?

        Result.invalid_input('ticket_id or number is required')
      end
      private_class_method :dispatch

      def self.by_id(ticket_id, context, options, only_project_id = nil)
        return Result.invalid_input('invalid ticket_id format') unless ticket_id.match?(UUID_FORMAT)

        ticket = base_scope(context, only_project_id: only_project_id).find_by(id: ticket_id)
        # `outside` is set from the READ, not from where the references happen to
        # sit. Two reasons, both found in the review of #642:
        #   * the `project` filter builds its own coverage by hand
        #     (Base.coverage_for) and never asks Scope#coverage, so a flag derived
        #     from the collection's position never reached that branch -- while
        #     this fallback still fired,
        #   * position also answers the WRONG question across areas: a ticket's
        #     project is not in the DOCUMENTS reach either, and a coverage for
        #     :documents would have flagged an outside read that never happened.
        # Only this line knows that something beyond the reach was actually read.
        # The rule itself (what the thread points at may be read; by id only) and
        # its two ⚠️ live at Base.referenced_record, shared with the knowledge tools.
        outside = ticket.nil? && (ticket = referenced_record(context, type: 'Ticket', id: ticket_id))
        return no_match("No ticket found for #{ticket_id}.") if ticket.nil?

        result = serve(ticket, context, options)
        result.coverage = outside_coverage(context, area: :tickets) if outside
        result
      end
      private_class_method :by_id

      def self.by_number(raw_number, context, options, only_project_id = nil)
        # Parsing is shared with the other number-addressed tools (TicketNumber).
        number = TicketNumber.parse(raw_number)
        return Result.invalid_input('invalid number (expected a ticket number like 187 or "#187")') if number.nil?

        tickets = base_scope(context, only_project_id: only_project_id).where(number: number).to_a
        return no_match("No ticket found for number #{number}.") if tickets.empty?
        return serve(tickets.first, context, options) if tickets.one?

        candidates(tickets, number, context, options)
      end
      private_class_method :by_number

      # Tenant- and project-scoped find: defense in depth on top of the PAT scope,
      # and the reason the same number in a sibling project stays out of reach.
      # Org-wide (S3a T3) the reach is the Scope's ticket projects — a number in a
      # no-access project resolves to nothing, so the lookup cannot even confirm
      # that the ticket exists (§12-S3a). Explicitly organisation-bound: tools
      # never lean on the ambient tenant (Context contract).
      def self.base_scope(context, only_project_id: nil)
        base = if context.project
                 context.project.tickets
               else
                 ids = only_project_id ? [only_project_id] : context.scope.project_ids(area: :tickets)
                 Ticket.where(organisation_id: context.organisation.id, project_id: ids)
               end
        # project: :organisation — the per-record policy reads the project's
        # organisation; without the preload each candidate costs a query.
        # Inside the read scope: a ticket the caller may not read is no ticket
        # (Base.readable_tickets), by id and by number alike.
        readable_tickets(context, base).includes(:creator, :assignees, project: :organisation)
      end
      private_class_method :base_scope

      # Serves ONE ticket: per-record authorization first, then the description,
      # readable comments and attachments. Resolve the surface's full-text limit
      # once for the description and the selected comment. These field limits do
      # not bound the whole result, particularly an ordinary page of 50 comments.
      def self.serve(ticket, context, options)
        authorize!(context, ticket, :show?)

        full_text_limit = context.chat ? MAX_ASSISTANT_FULL_TEXT_CHARS : MAX_FULL_TEXT_CHARS
        serializer = Tickets::Serializer.new(current_user: context.actor)
        reading = Tickets::Reading.new(serializer: serializer)
        comments = options.post_id ? one_post(reading, ticket, options, limit: full_text_limit) : post_page(reading, ticket, options)
        return comments if comments.is_a?(Result)

        description_cap = options.full_text ? full_text_limit : MAX_BODY_CHARS
        payload = cap_description(serializer.full(ticket, posts: false), description_cap)
                  .merge(comments)
                  .merge(attachment_page(reading, ticket, options.paging.attachments_page))
        # Cite the ticket: the citation's area ('tickets') is what makes the answer
        # rights-gated for OTHER readers of the shared chat, not only for the asker.
        # Keep the ids of comments actually handed to the model, including private
        # ones. A later explicit save must recheck those records as well as the ticket.
        citation = Lalabase::Citations.ticket(ticket).merge(post_ids: payload[:posts].pluck(:id))
        json_result(payload, citations: [citation])
      end
      private_class_method :serve

      # Tickets::Reading#post_page with each comment capped.
      def self.post_page(reading, ticket, options)
        page = reading.post_page(ticket, options.paging)
        page.merge(posts: page[:posts].map { |post| cap_post(post, MAX_BODY_CHARS) })
      end
      private_class_method :post_page

      # The one comment of post_id, within the surface's full-text limit, picked
      # from the reader's readable comments of THIS ticket. Hidden, foreign and
      # missing comments all answer "No comment found".
      def self.one_post(reading, ticket, options, limit:)
        page = reading.one_post(ticket, options.post_id)
        return no_match("No comment found for #{options.post_id}.") if page.nil?

        page.merge(posts: page[:posts].map { |post| cap_post(post, limit) }, post_id: options.post_id)
      end
      private_class_method :one_post

      # Merged onto the payload rather than built inside #full: the attachments
      # come from their own serializer method, because #full is shared with the HTTP
      # API and must not grow a body of file text there.
      #
      # Tickets::Reading#attachment_page (bounded in the query, with the honest
      # total) with each file's text capped.
      def self.attachment_page(reading, ticket, page)
        files = reading.attachment_page(ticket, page)
        files.merge(attachments: files[:attachments].map { |file| cap_attachment(file) })
      end
      private_class_method :attachment_page

      # §9.2: an ambiguous number answers with candidates (project, number, title),
      # never with an error — the model turns the list into a follow-up question the
      # user answers with one click. Reachable since S3a T3 widened the scope to
      # the org; the payload shape is shared with the other number-resolving tool
      # (Tools::TicketCandidates).
      def self.candidates(tickets, number, context, options)
        readable = readable_candidates(tickets, context)
        return no_match("No ticket found for number #{number}.") if readable.empty?
        return serve(readable.first, context, options) if readable.one?

        json_result(
          TicketCandidates.payload(readable, number, limit: MAX_CANDIDATES),
          # Candidate titles are content. An answer drawn only on this list with no
          # cited area counts as content-free and reaches every reader of a shared
          # chat ungated — the failure mode of PR #534.
          citations: readable.first(MAX_CANDIDATES).map { |ticket| Lalabase::Citations.ticket(ticket) }
        )
      end
      private_class_method :candidates

      # Filters instead of raising: once several projects are in reach, a single
      # forbidden ticket must not sink the whole answer. One policy pass per
      # candidate is the whole rights check here — the path is reachable only
      # with an org-wide scope, which the MCP dispatcher never builds, so the D7
      # record-mode tripwire (Base.authorize! marking the recorder) has no
      # observer on it. Should MCP ever get org-wide reach, the survivors must
      # go through Base.authorize! again (T3 second review).
      def self.readable_candidates(tickets, context)
        tickets.select { |ticket| Pundit.policy!(context.actor, ticket).show? }
      end
      private_class_method :readable_candidates

      def self.no_match(message)
        Result.new(content: message, citations: [], kind: :empty)
      end
      private_class_method :no_match

      def self.cap_description(full, limit)
        full.merge(description_html: truncate(full[:description_html], limit),
                   description_text: truncate(full[:description_text], limit))
      end
      private_class_method :cap_description

      def self.cap_attachment(file)
        file.merge(text: truncate(file[:text], MAX_ATTACHMENT_TEXT_CHARS))
      end
      private_class_method :cap_attachment

      def self.cap_post(post, limit)
        post.merge(body_html: truncate(post[:body_html], limit), body_text: truncate(post[:body_text], limit))
      end
      private_class_method :cap_post

      # Paging is Tickets::Reading's (MCP clamps posts_per_page, as it always
      # did); full_text and post_id belong to this tool.
      def self.parse_options(args)
        Options.new(
          paging: Tickets::Reading.options(args, over_max: :clamp),
          full_text: full_text_arg(args[:full_text]),
          post_id: post_id_arg(args[:post_id])
        )
      end
      private_class_method :parse_options

      # A boolean, as the MCP schema declares it: the in-app assistant calls the
      # tool without that schema check, and a "true" there must not read as false.
      def self.full_text_arg(value)
        return false if value.nil? || value == '' || value == false
        return true if value == true

        raise Tickets::Reading::InvalidOption, "invalid full_text #{value.inspect} (true or false)"
      end
      private_class_method :full_text_arg

      def self.post_id_arg(value)
        raw = value.to_s.strip
        return nil if raw.empty?
        raise Tickets::Reading::InvalidOption, 'invalid post_id format' unless raw.match?(UUID_FORMAT)

        raw
      end
      private_class_method :post_id_arg

      # The limit is a parameter because the attachments answer to a smaller one; the
      # marker and the "nil stays nil" rule live in Base.cap_text, shared with the
      # knowledge tools, so a truncated attachment text, note or document is
      # recognisable as the same thing as a truncated body.
      def self.truncate(value, limit = MAX_BODY_CHARS)
        cap_text(value, limit)
      end
      private_class_method :truncate
    end
  end
end
