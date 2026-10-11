# frozen_string_literal: true

module Documentation
  # Resolves a `lalabase://<type>/<uuid>` link (KnowledgeLink) found in a synced doc
  # page to the in-app target it points at — but ONLY when that target is reachable
  # from the page's own set. A standalone, unit-testable object (no view/job context):
  # the renderer calls #resolve once per candidate href.
  #
  # Resolvable means ALL of:
  #   * the string is a well-formed KnowledgeLink of a known type, and
  #   * the target row exists, in the same project as the documentation set.
  #
  # Scoping is by project_id, which is stronger than it looks: a project belongs to
  # exactly one organisation, so `project_id: set.project_id` rejects BOTH a note from
  # another project of the same org (cross-project leak — project-access audit) AND a
  # UUID that happens to exist in another tenant (cross-tenant). During sync the job's
  # with_tenant block additionally arms acts_as_tenant's org default scope (defense in
  # depth). The id has already been shape-checked by KnowledgeLink.parse, so find_by
  # can never hit the uuid column with a non-UUID.
  #
  # A miss for ANY reason returns nil. "Does not exist", "wrong project" and "wrong
  # tenant" are therefore INDISTINGUISHABLE to the caller and produce identical output
  # — no existence oracle that would let a doc reader probe raw UUIDs. The renderer
  # leaves an unresolved link's href untouched (the sanitizer then drops the unknown
  # `lalabase:` scheme), so the visible result is the same non-link in every miss case.
  class KnowledgeLinkResolver
    ResolvedLink = Struct.new(:target, :path, keyword_init: true)

    def initialize(documentation_set:)
      @documentation_set = documentation_set
    end

    # Single link → ResolvedLink or nil. A thin wrapper over the batch path so a
    # caller (or a unit test) can resolve one link without assembling a list.
    #
    # @param url [String] a candidate href from the rendered markdown
    # @return [ResolvedLink, nil]
    def resolve(url)
      resolve_all([url])[url]
    end

    # Resolves many candidate hrefs in a FIXED number of queries — one per knowledge
    # type actually present, not one per link. A doc page may carry dozens of links;
    # a per-link find_by would be a classic N+1 (Prosopite would flag it, and rightly).
    #
    # @param urls [Array<String>] candidate hrefs
    # @return [Hash{String => ResolvedLink}] only the RESOLVABLE urls appear as keys;
    #   an unresolvable one (bad shape, wrong project, wrong tenant, missing) is simply
    #   absent — the caller treats "absent" as "leave the link untouched", so every
    #   miss reason produces the identical observable result (no existence oracle).
    def resolve_all(urls)
      parsed = parse_urls(urls)
      targets = load_targets(parsed.values)

      parsed.each_with_object({}) do |(url, pair), out|
        target = targets.dig(pair[:type], pair[:id])
        out[url] = ResolvedLink.new(target: target, path: path_for(pair[:type], target)) if target
      end
    end

    private

    # { url => {type:, id:} } for the well-formed knowledge links only (uniq: repeated
    # links collapse to one entry so the same note is never looked up or indexed twice).
    def parse_urls(urls)
      urls.uniq.each_with_object({}) do |url, out|
        pair = KnowledgeLink.parse(url)
        out[url] = pair if pair
      end
    end

    # One query per type: model.where(id: [...], project_id:). Returns
    # { type => { id => record } } for O(1) lookup while rewriting each anchor.
    #
    # Isolation lives here: project_id scoping rejects a target from another project
    # (and, since a project has one org, from another tenant); during sync the job's
    # with_tenant block also arms acts_as_tenant's org scope. The ids were UUID-shape
    # checked by KnowledgeLink.parse, so the uuid column is never hit with junk.
    def load_targets(pairs)
      pairs.group_by { |pair| pair[:type] }.transform_values do |group|
        model = KnowledgeLink.entry(group.first[:type])[:model].constantize
        ids = group.map { |pair| pair[:id] }.uniq
        model.where(id: ids, project_id: @documentation_set.project_id).index_by(&:id)
      end
    end

    def path_for(type, record)
      KnowledgeLink.entry(type)[:path].call(routes, record)
    end

    # Path helpers live on the view/controller layer; the renderer (and thus this
    # resolver) runs inside a background job, so we reach them via the app's route set.
    def routes
      Rails.application.routes.url_helpers
    end
  end
end
