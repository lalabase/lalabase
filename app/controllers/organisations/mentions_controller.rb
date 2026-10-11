# frozen_string_literal: true

module Organisations
  # Serves the @-mention picker for the wiki editor (Lexxy's <lexxy-prompt src>).
  # Lexxy requests GET ...?filter=<typed term> and expects an HTML fragment of
  # <lexxy-prompt-item> elements.
  #
  # SECURITY (Lane B critical): candidates run through policy_scope(Note)/policy_scope(Document),
  # so only notes/documents the current user may READ are ever suggested — and the sgid that
  # ends up in the editor is minted server-side from a policy-scoped record, never supplied by
  # the client. The result is additionally narrowed to the project being edited.
  class MentionsController < Organisations::BaseController
    MAX_RESULTS = 10

    def index
      @project = current_organisation.projects.find(params[:project_id])
      @mentionables = mention_candidates(params[:filter].to_s.strip)
      render layout: false
    end

    private

    # policy_scope is the access gate; the project filter is the scope decision (Lane B:
    # mentions are project-local). Notes carry their own title column; a Document's title
    # lives on its current_version, so that arm joins and filters there.
    def mention_candidates(term)
      # Preload what the prompt_item render touches per row (wiki_mention_path → project +
      # organisation; document.title → current_version) to avoid an N+1 per candidate.
      # The docs arm keeps joins(:current_version) for the title filter; includes adds the
      # preload (separate query), so it is loaded once for all rows, not once per row.
      notes = policy_scope(Note).where(project: @project).includes(:project, :organisation)
      docs  = policy_scope(Document).where(project: @project)
                                    .joins(:current_version)
                                    .includes(:current_version, :project, :organisation)

      if term.present?
        like = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
        notes = notes.where('notes.title ILIKE ?', like)
        docs  = docs.where('document_versions.title ILIKE ?', like)
      end

      (notes.limit(MAX_RESULTS).to_a + docs.limit(MAX_RESULTS).to_a)
        .sort_by { |record| record.title.to_s.downcase }
        .first(MAX_RESULTS)
    end
  end
end
