# frozen_string_literal: true

module Lalabase
  module Tools
    # Org-wide reach of one assistant call (Plan §9.1, S3a T3).
    # Entry point: project_ids / projects / coverage
    #
    # The Runner sets this on the Context of an org thread (project nil) and the
    # Retriever resolves through it too; the MCP dispatcher never builds one
    # (R-M5: `project` stays the single-project path). It answers the one
    # question every org-wide reader has: "which
    # projects may THIS asker read for THIS area?" — through
    # AccessCheck::ProjectAccessService.accessible_project_ids, the same source
    # the per-area Pundit scopes use, so tool reach and UI reach cannot drift.
    #
    # One rule lives HERE and nowhere else, because the T3 second review found it
    # enforced by hand (and once wrongly) across the org paths:
    #   * Archived projects are out of the default reach. The assistant would
    #     otherwise name stilled projects like running ones and count them in the
    #     L7 total. T5 kept them out of the CHIP as well (decided 25.08.2026), so
    #     this is the whole rule -- no surface reopens an archived project.
    # Fail-closed: no actor means no projects.
    #
    # #coverage is the L7 contract: `searched` (projects in reach for the area)
    # against `total` (active projects of the organisation). The answer's
    # narrowing notice is rendered deterministically from these numbers — a
    # sum over 3 of 12 projects must never wear an org-wide label.
    class Scope
      attr_reader :organisation, :actor

      # THE way to build a scope for a chat (S3a T5). Two callers resolve the
      # org-wide reach -- Tools::Runner for the tool rounds and
      # ProjectRag::Retriever for the content layer -- and each used to construct
      # this by hand. Two constructions are two places to forget the chip, which
      # is precisely the shape of defect this slice kept producing elsewhere.
      # Returns nil for anything that is not an org thread: the single-project
      # path stays untouched (R-M5).
      def self.for(chat:, actor:)
        return nil unless chat&.org_thread?

        new(organisation: chat.organisation, actor: actor,
            only_project_id: chat.scope_project_id, references: chat.scope_references)
      end

      def initialize(organisation:, actor:, only_project_id: nil, references: [])
        @organisation = organisation
        @actor = actor
        @only_project_id = only_project_id
        @stored_references = references
        @project_ids = {}
        @area_reach = {}
      end

      # The chip's project, IF the choice still holds. A choice that no longer
      # resolves -- archived, deleted, or no longer readable by THIS asker -- is
      # NO choice: the thread widens back to the asker's full reach rather than
      # answering out of an empty one, and the chip renders THIS value, so it says
      # "Alle Projekte" the moment that happens instead of claiming a narrowing
      # that is gone.
      #
      # Resolved through the SAME owner the write path validates against
      # (Chats::AssistantScopeOptions), and that is the whole point: the write
      # path checks the rights ONCE, at the moment of storing. Rights change
      # afterwards. Without the check here a member who lost access to the pinned
      # project would keep its NAME in the system prompt and in the coverage
      # sentence -- a name is exactly what the sidebar withholds from someone
      # without access -- while the reach silently intersected down to nothing and
      # the chip, whose option list IS policy-scoped, showed "Alle Projekte".
      def selection
        return @selection if defined?(@selection)

        @selection = @only_project_id && offerable_projects.find_by(id: @only_project_id)
      end

      # The thread's reference collection, resolved, in STORED order
      # (Bezugs-Sammlung plan §6). Same design as #selection one level down, and
      # for the same reason: a stored entry is not the answer, it is a question
      # asked again against the asker's CURRENT reach. An object whose project was
      # archived, whose access was taken away, or which moved to another
      # organisation stops being a reference instead of becoming a name the asker
      # may not see.
      #
      # ⚠️ Not resolvable means WITHOUT A TRACE. No error, no message, no name --
      # not in the chip, not in data-reference-keys, not in the system prompt. A
      # name is exactly what this app withholds from someone without access, and a
      # refusal that names its subject discloses it.
      #
      # ONE query per type, then ONE project load by hand over the union of the
      # project ids. `includes` per relation would be a query per type PLUS a
      # query per type for the projects; the projects are needed by the coverage
      # sentence and by the prompt, and they are mostly the same handful.
      def references
        @references ||= resolve_references
      end

      # The record an entry is ALLOWED to mean for this asker, or nil. Public
      # because the write path needs exactly the answer the read path gets: "may
      # this object stand on this thread?" is ONE question, and the whole safety of
      # the reference collection rests on it having one place. #references asks it
      # about what is already stored; Actors::AddChatReference asks it about what
      # the user just picked, before storing anything.
      #
      # Asked against the UNNARROWED area reach, and the reason changed with E3.
      # It used to be a CYCLE (resolve_project_ids applied the reference, so asking
      # it through project_ids would have fed itself); since E3 the reference
      # narrows nothing and no cycle is left. What remains is a decision: the chip
      # says where to SEARCH, and what a thread may point AT is not a search. A
      # reference to a ticket outside the chip therefore stands -- and stays
      # readable, see GetTicket.referenced_ticket, with the coverage line saying so.
      #
      # Fail-closed on an unregistered type: no entry, no query, nil.
      def resolve_reference(type:, id:)
        return nil if id.blank? || actor.nil?

        entry = Assistant::ReferenceRegistry.entry_for(type)
        return nil if entry.nil?

        reachable_for(entry).find_by(id: id)
      end

      # The projects any org-wide reach is drawn from (active ones, see above).
      def projects
        @projects ||= organisation.projects.active
      end

      # What the chip may offer this asker, i.e. what a stored choice is allowed
      # to still mean. ONE owner, shared with the chip and with
      # AssistantChatsController#update.
      def offerable_projects
        @offerable_projects ||= Chats::AssistantScopeOptions.call(user: actor, organisation: organisation)
      end

      # Project ids the actor may READ for `area`, memoized per area.
      def project_ids(area:)
        @project_ids[area.to_sym] ||= resolve_project_ids(area.to_sym)
      end

      # Project ids whose CODE the actor may reach: the projects with a connected
      # repository, narrowed like every other reach.
      #
      # NOT an area reach, and that is the whole point. Repository visibility is
      # `chats:read OR documentation:write` (ProjectRepositoryPolicy::Scope) --
      # ProjectPermission has no `repositories` area at all, so there is no single
      # area to ask for. Asking for `:chats` here would be a hand-written near-copy
      # that silently drops the documentation half, which is the exact shape of
      # defect this feature has produced before. The policy scope stays the one
      # owner of the rule and this method is its one caller; the precedent is
      # SummarizeTimeSessions, whose reach comes from TimeSessions::ViewingScope for
      # the same reason.
      #
      # Memoized like #project_ids: the five code tools all ask, and up to five
      # policy-scope queries per answer is what memoization here is for.
      def code_project_ids
        @code_project_ids ||= resolve_code_project_ids
      end

      # L7 numbers for `area`: how many projects the call actually reaches,
      # out of how many the organisation has (the fraction is named on purpose;
      # the count alone is the price of an honest answer).
      def coverage(area:)
        coverage_with(searched: project_ids(area: area).size)
      end

      # Same shape, for a caller that narrowed FURTHER on its own and therefore
      # knows a smaller number than the area reach (SummarizeTimeSessions filters
      # again by time permission). It used to build the hash by hand, which meant
      # the shape lived in two places -- and the T5 `chosen` key promptly reached
      # only one of them.
      #
      # `chosen:` is for the OTHER narrowing the user asks for: the per-call
      # `project` filter, which leaves no trace on the thread and is therefore
      # invisible to #selection. Both are the user's own choice, so both earn the
      # named sentence -- the counted one means "your rights stopped here", and a
      # question that itself named a project must not wear it.
      # `outside:` is the E3 companion of the reach fix in GetTicket (review of
      # #642): a thread may now READ an object it points at even when the chip
      # searches elsewhere, so "Durchsucht: nur Nordlicht" would otherwise become a
      # small lie the moment that happens.
      #
      # ⚠️ Set by the READER, never derived here. The first version asked "does a
      # reference sit outside the searched ids", and that answers the wrong
      # question twice: it misses the `project` filter (which builds its coverage
      # without this method at all) and it fires across AREAS, where a ticket's
      # project is legitimately absent from the documents reach. Only the call that
      # actually fell back to the reference knows -- see GetTicket.by_id.
      def coverage_with(searched:, chosen: nil, outside: false)
        numbers = { searched: searched, total: total_projects }
        # ⚠️ `outside` REPLACES the named sentence, it does not decorate it. The
        # call left the chosen project, so wearing its name would be the very lie
        # this flag exists to prevent ("Durchsucht: nur A" over an answer that read
        # from B). Deciding it here rather than at the call site keeps the shape in
        # one place, which is why this method exists at all.
        return numbers.merge(outside: true) if outside

        # `chosen` (T5) is what lets the answer tell a narrowing the user ASKED
        # for apart from one their rights imposed. It travels with the answer, so
        # a reply copied into a ticket still says what it looked at -- the chip
        # is not there any more once the answer leaves the panel.
        # ⚠️ The reference used to be a third source here, naming its object's
        # project. It went with the narrowing itself in S2 (E3), and it had to go
        # WITH it: a collection may span several projects, so "the project of the
        # reference" is not definable, and naming one would report a confinement
        # that no longer exists. The reference names the SUBJECT now; only the chip
        # and the per-call filter narrow, and only they earn this sentence.
        name = chosen.presence || selection&.name
        return numbers unless name

        numbers.merge(chosen: name)
      end

      def total_projects
        @total_projects ||= active_project_ids.size
      end

      private

      # Loaded ONCE per scope: every area intersects against the same list, and
      # a query per area would be an N+1 across the registry's types.
      def active_project_ids
        @active_project_ids ||= projects.pluck(:id)
      end

      # The area reach BEFORE any of the user's own narrowings: what the asker may
      # read at all, minus archived projects.
      #
      # Memoized per area like #project_ids, and for a sharper reason than saving
      # a query: TWO callers ask for the same area. resolve_project_ids asks for
      # the area it is resolving, and the reference resolution asks for its type's
      # area, so a thread with a ticket reference paid for :tickets twice. That reach is
      # not a lookup -- active_member?, the admin short circuit, the
      # global-permission check, then a pluck -- and the job builds up to three
      # scopes per answer.
      def area_reach(area)
        @area_reach[area] ||= resolve_area_reach(area)
      end

      def resolve_area_reach(area)
        # An account_admin reads every project of the organisation, whatever the area
        # (ProjectAccessService#accessible_project_ids, the branch above the permission
        # lookups). So their reach does not depend on `area` at all, and asking per area
        # meant one identical `projects` query per content type -- seven of them on every
        # question, measured by Prosopite once projekt_chat_abbau put every asker on this
        # path. Before that cut an admin asking inside a project took the single-project
        # route and never got here.
        return active_project_ids if actor&.account_admin_in?(organisation)

        # An inactive member still gets nothing, org-wide included: the rule moved
        # into accessible_project_ids itself (#603), which is also where the chip's
        # option list picks it up (AssistantScopeOptions → ProjectPolicy::Scope).
        accessible = AccessCheck::ProjectAccessService.accessible_project_ids(
          actor, organisation, action: :read, area: area
        )
        accessible & active_project_ids
      end

      # ONE narrowing, and it is the chip: intersection, never replacement, so it
      # can only take projects away from what the asker may read.
      #
      # ⚠️ There used to be a second line here, intersecting with the project of the
      # standing reference. E3 (plan §2.2, §10 S2) removed it, and this is the one
      # behaviour change of the whole undertaking. Two reasons, and the second is
      # the one that forced it:
      #   * A collection may hold objects from several projects, so "the project of
      #     the reference" stops being definable the moment the limit rises above
      #     one. `references.first` would have narrowed to whichever was set first
      #     while the chip named the last.
      #   * It was never asked for. The button says "Assistent", and it silently
      #     overwrote a "Sucht in" the user had deliberately chosen -- so somebody
      #     who works mostly in one project lost that choice to every reference
      #     click, and got it cleared again by the x.
      # A reference names the SUBJECT of the conversation ("Rueckfragen ohne
      # eigenen Gegenstand meinen dieses Ticket"). Where to look is the chip's
      # question, and it is now the only one that answers it.
      def resolve_project_ids(area)
        return [] if actor.nil?

        reach = area_reach(area)
        reach &= [selection.id] if selection
        reach
      end

      # Same two narrowings #resolve_project_ids applies, over a different source:
      # active projects only, then the chip. The chip intersects here too, which is
      # what makes it safe -- a chip pointing at a project whose code this asker may
      # NOT reach leaves nothing rather than becoming a way in.
      #
      # The relation handed to policy_scope! is bound to THIS organisation
      # explicitly: the policy resolves its rights against the ambient tenant, and a
      # tool must not lean on it for the rows as well (Context contract).
      def resolve_code_project_ids
        return [] if actor.nil?

        readable = Pundit.policy_scope!(actor, ProjectRepository.where(organisation_id: organisation.id))
        reach = readable.distinct.pluck(:project_id) & active_project_ids
        reach &= [selection.id] if selection
        reach
      end

      # One query per TYPE, then one project load by hand, then the stored order
      # restored -- grouping by type is what makes the query count independent of
      # the number of entries, and it is also what loses the order.
      def resolve_references
        entries = stored_entries
        return [] if entries.empty? || actor.nil?

        found = entries.group_by { |entry| entry[:type] }.each_with_object({}) do |(type, group), acc|
          registered = Assistant::ReferenceRegistry.entry_for(type)
          next if registered.nil?

          # to_a and not find_each: the batch loop is for tables, this is at most
          # MAX_REFERENCES rows named by primary key.
          reachable_for(registered).where(id: group.pluck(:id)).to_a.each do |record|
            acc[Assistant::ReferenceRegistry.key_of(record)] = record
          end
        end

        ordered = entries.filter_map { |entry| found[Assistant::ReferenceRegistry.key_for(**entry)] }
        preload_projects(ordered)
        ordered
      end

      # The captured SNAPSHOT as pairs, malformed and unregistered entries dropped.
      # Fail-closed reading: what the registry does not know is not there, which is
      # the same answer a deregistered type gets.
      #
      # The rule itself lives in the registry, which is why this reads a snapshot
      # through stored_entries_in rather than repeating the filter_map here.
      def stored_entries
        Assistant::ReferenceRegistry.stored_entries_in(@stored_references)
      end

      # The relation a type's entries may be drawn from: the type's OWN policy,
      # handed the unnarrowed area reach. See ReferenceRegistry for why the actor
      # travels along even where a project filter would do.
      def reachable_for(registered)
        registered.reachable.call(organisation, actor, area_reach(registered.area))
      end

      # ONE project load for the whole collection instead of a lazy association per
      # record: the coverage sentence and the system prompt both name the project,
      # and at ten entries that is ten queries for a handful of distinct projects.
      def preload_projects(records)
        ids = records.filter_map { |record| record.project_id if record.respond_to?(:project_id) }.uniq
        return if ids.empty?

        by_id = organisation.projects.where(id: ids).index_by(&:id)
        records.each do |record|
          next unless record.respond_to?(:project_id)

          project = by_id[record.project_id]
          record.association(:project).target = project if project
        end
      end
    end
  end
end
