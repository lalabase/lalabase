# frozen_string_literal: true

# Entry point: .path_for
module Lalabase
  # THE address of a citation's target: where a click on this source goes.
  #
  # Extracted from Neo::Chat::CitationListComponent (Feinschliff C) because the
  # prose now links the same objects the source list links. Two builders would be
  # two addresses: the source row and the sentence above it would drift apart the
  # first time a route gains a parameter, and the drift would be invisible — both
  # would still lead somewhere.
  #
  # Built from the FROZEN ids on the citation, so no record is loaded. Whether the
  # target still exists is a separate question with its own owner
  # (Lalabase::CitationTargets); a caller that offers a link asks both.
  #
  # nil when there is no organisation, no project to hang the route on, or the type
  # carries no page of its own.
  module CitationLink
    module_function

    def path_for(citation, organisation:, project: nil)
      return nil if organisation.nil? || !citation.is_a?(Hash)
      # Lalabase's own texts live outside every organisation and project (/hilfe), so the
      # project fallback below must not decide whether they get a link.
      return product_path(citation) if citation['type'] == 'help_page'

      target_project = citation['project_id'].presence || project
      return nil if target_project.nil?

      build(citation, organisation, target_project)
    end

    # A page of Lalabase's own texts, addressed by its source and slug (the citation's id).
    # Branches on the source so the news (S3) get their own address rather than the help's.
    def product_path(citation)
      slug = citation['id']
      return nil if slug.blank?

      case citation['source']
      # The help page here when this instance carries the handbook, the public
      # documentation when it does not: a citation must lead somewhere.
      when ProductKnowledge::Sources::HELP
        # The language the page was READ in, from the citation itself. NOT
        # I18n.locale: this renders again inside the streaming job, where
        # nothing sets it and the app default (German) would win, so an English
        # reader's streamed citation and the same citation on page load pointed
        # at two different addresses.
        Docs::HelpLink.url(slug: slug, locale: Docs::Contract.locale_or_default(citation['locale']))
      end
    end

    # Route helpers without a view context: this runs in the streaming broadcast
    # too, where there is no request.
    #
    # ⚠️ NOT ActionController::Base.helpers, which carries the framework helpers and
    # the routes but NOT this app's own helper modules — assistant_report_list_path
    # is one of those and raised NoMethodError there. And NOT an extended Object
    # either: that shipped once and answered 500 on every cited message, see
    # Lalabase::RouteContext for why the difference is invisible to a spec.
    #
    # Built per call rather than memoised: a module-level instance would outlive the
    # dev reloader and keep a stale copy of the class it came from.
    def helpers
      RouteContext.new
    end

    def build(citation, organisation, project)
      case citation['type']
      when 'ticket'        then record_path(:ticket, organisation, project, citation['id'])
      when 'post'          then record_path(:ticket, organisation, project, citation['ticket_id'])
      when 'note'          then record_path(:note, organisation, project, citation['id'])
      when 'document'      then record_path(:document, organisation, project, citation['id'])
      when 'documentation' then documentation_path(organisation, project, citation['set_id'], citation['page'])
      when 'meeting'       then record_path(:meeting, organisation, project, citation['id'])
      # An analysis has no own page → deep-link to its MEETING via meeting_id (Slice 7b).
      when 'meeting_analysis' then record_path(:meeting, organisation, project, citation['meeting_id'])
      # A report has no record: the link reopens the project's time list with the
      # filters the numbers were computed under (frozen on the citation). ONE owner
      # of this address since S3c T3 — the panel showing the same report leaves into
      # the same list, and two hand-built versions are two lists that drift apart.
      when 'time_report' then helpers.assistant_report_list_path(organisation, project, citation['filters'])
      end
    end

    def record_path(kind, organisation, project, id)
      return nil if id.blank?

      helpers.public_send("organisation_project_#{kind}_path", organisation, project, id)
    end

    # A doc page has no REST id of its own in the browsing route — it is addressed
    # by its set id + repo-relative path as query params.
    def documentation_path(organisation, project, set_id, page)
      return nil if set_id.blank? || page.blank?

      helpers.organisation_project_documentation_index_path(organisation, project, set_id: set_id, page: page)
    end

    private_class_method :product_path, :helpers, :build, :record_path, :documentation_path
  end
end
