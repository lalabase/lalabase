# frozen_string_literal: true

module Lalabase
  module Tools
    # Fetches a single note as JSON: head fields and its text
    # (doc/assistent_wissen_kontext_plan.md, step 2). Record-mode: the tool MUST
    # authorize the individual note via Base.authorize!(:show?).
    #
    # This is the only road from a note REFERENCE to the note's content: the
    # system prompt names a referenced note by title and id only (Bezugs-Sammlung
    # E5), and the content retrieval finds a note only where it is embedded. A
    # question like "welche Schritte fehlen hier?" is answered from this payload or
    # from the title alone.
    #
    # The text is the stored MARKDOWN where the note has one (the wiki lifecycle
    # derives it on every content save), because headings, lists and tables are
    # what a question about a note is usually about; the plain text is the
    # fallback for a note the backfill has not reached. `text_format` says which.
    #
    # Caps: the text is cut at MAX_TEXT_CHARS with a marker, and the payload says
    # so (text_truncated, text_length) -- a cut text does not support a complete
    # analysis, and the model has to be able to say that.
    class GetNote < Base
      # Same as the ticket body: a note is one text, and the run's whole tool
      # budget (Runner::DEFAULT_MAX_TOOL_RESULT_CHARS) bounds ten of them.
      MAX_TEXT_CHARS = 8_000

      def self.authorization_mode
        :record
      end

      # Authorizes per record against context.actor -- declared so the Runner's
      # fail-closed bar refuses the call when no user is in the context.
      def self.requires_actor?
        true
      end

      def self.tool_name
        'get_note'
      end

      def self.description
        'Fetches a single note as JSON by note_id (its UUID): title, project, tags, ' \
          'dates and its text. text_format says whether the text is "markdown" ' \
          '(headings, lists and tables preserved) or "plain". Use it when a question ' \
          'is about the content of a note the conversation refers to; the system ' \
          'prompt names the ids of referenced notes. Long texts are cut: ' \
          'text_truncated says so and text_length is the full length, and a cut ' \
          'text does not support a complete analysis, so say so. Authorized per ' \
          'record against the asking user; a note outside their reach is "not found".'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            note_id: { type: 'string', description: 'UUID of the note to fetch.' }
          },
          required: ['note_id']
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'project context missing') if context.project.nil? && context.scope.nil?

        args = symbolized(args)
        note_id = args[:note_id].to_s.strip
        return Result.new(error: 'invalid note_id format') unless note_id.match?(UUID_FORMAT)

        note = base_scope(context).find_by(id: note_id)
        # What the thread points at may be read even when the chip searches
        # elsewhere (Base.referenced_record); the read sets `outside`, nothing else.
        outside = note.nil? && (note = referenced_record(context, type: 'Note', id: note_id))
        return no_match("No note found for #{note_id}.", context) if note.nil?

        result = serve(note, context)
        result.coverage = outside ? outside_coverage(context, area: :notes) : coverage_for(context, area: :notes)
        result
      end

      # Tenant- and project-scoped find: org-wide the reach is the Scope's NOTES
      # projects (a note in a no-access project resolves to nothing, so the lookup
      # cannot even confirm that it exists). Explicitly organisation-bound: tools
      # never lean on the ambient tenant (Context contract).
      def self.base_scope(context)
        base = if context.project
                 context.project.notes
               else
                 Note.where(organisation_id: context.organisation.id, project_id: context.scope.project_ids(area: :notes))
               end
        # project: :organisation -- the per-record policy reads the project's
        # organisation; without the preload the check costs a query.
        base.includes(project: :organisation)
      end
      private_class_method :base_scope

      # Serves ONE note: per-record authorization first (raises when denied), then
      # the capped payload, cited with the notes area so the answer stays gated
      # for anyone else who may read the thread.
      def self.serve(note, context)
        authorize!(context, note, :show?)

        json_result(payload(note), citations: [Lalabase::Citations.note(note)])
      end
      private_class_method :serve

      def self.payload(note)
        format, text = text_of(note)
        {
          id: note.id,
          title: note.title,
          project: { id: note.project_id, name: note.project.name },
          tags: note.tags.map(&:name),
          created_at: note.created_at.iso8601,
          updated_at: note.updated_at.iso8601,
          text_format: format,
          text_length: text.to_s.length,
          text_truncated: text.to_s.length > MAX_TEXT_CHARS,
          text: cap_text(text, MAX_TEXT_CHARS)
        }
      end
      private_class_method :payload

      # Markdown first, plain text second, and the rich text itself as the last
      # resort for a note that predates both derived columns.
      def self.text_of(note)
        return ['markdown', note.markdown_body] if note.markdown_body.present?
        return ['plain', note.plain_text_version] if note.plain_text_version.present?

        ['plain', note.content&.to_plain_text.to_s]
      end
      private_class_method :text_of

      # "Not found" wears the reach like every other org-wide outcome (L7).
      def self.no_match(message, context)
        Result.new(content: message, citations: [], kind: :empty, coverage: coverage_for(context, area: :notes))
      end
      private_class_method :no_match
    end
  end
end
