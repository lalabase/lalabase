# frozen_string_literal: true

# What E3 leaves behind (Bezugs-Sammlung plan §10 S2), swept up once.
# Entry point: call
#
# Until S2 a reference WROTE its object's project into chats.scope_project_id.
# After the decoupling nobody writes that column but the user, so a thread that
# carried a reference may be left claiming a narrowing its owner never chose: the
# chip says "Sucht in: Nordlicht Software" and the answer really is confined to
# it, while the click that caused it was labelled "Assistent".
#
# ⚠️ "The thread carries references" does NOT mean "the project was inherited",
# and an earlier version of this sweep assumed it did. On the deployed code the
# chip is a free select (Neo::Chat::ScopeChipComponent; the controller permits
# chat[scope_project_id]) and it is never disabled while a reference stands. A
# user could set a reference and THEN choose a different project -- months ago,
# not merely in the window between this deploy and this run -- and the sweep would
# have deleted that choice silently, with nothing anywhere recording what it was.
#
# The signal that does carry is the inverse of the only write that ever inherited:
# Actors::AddChatReference wrote exactly `added.project_id`. So a chip naming a
# project that NONE of the thread's references lives in cannot be inherited, and
# is left alone. Three verdicts, and #verdict is where they are decided.
#
# ⚠️ What stays undecidable, said out loud: a user who deliberately picked the
# very project their reference lives in is indistinguishable from the inherited
# case -- the column records a value, not an author, and Chat keeps no activity
# trail to reconstruct one from. That residue is cleared, and it is why the run
# reports its ROWS and not just a count: the reference stands right beside the
# chip naming the same project, and the row is what an operator restores from.
#
# ⚠️ NOT in Lalabase::DataBackfills, and this is the whole decision. The list runs
# on EVERY deploy, and after E3 a thread may perfectly well carry references AND a
# deliberately chosen project: the sweep would wipe that choice again and again,
# for ever. The §4.3 backfill may live in the hook precisely because its WHERE
# stops being satisfiable after the first run; this one never runs empty. Same
# question, two answers, one page apart in the plan -- that pairing is what Rev. 7
# is about, and it is why this comment states the criterion rather than the habit.
#
# Deliberately not an Actor: the actor seam carries request writes (Current.user,
# activity tracking, side-effect jobs). This is an operator-run maintenance sweep
# with no acting user and no side effects -- the same shape, and the same tenancy
# decision, as the removed ownership backfill was.
module Chats
  class ScopeProjectCleanup
    # Raised instead of sweeping when the registry knows a type this sweep cannot
    # map to a project. See #ensure_registry_is_mapped!.
    UnmappedType = Class.new(StandardError)

    # One thread the run cleared, in the form an operator needs to undo it: the
    # thread, and the value that was in the column.
    Row = Struct.new(:chat_id, :organisation_id, :project_id, keyword_init: true)

    # cleared      — threads whose chip was emptied (dry run: would be). Taken from
    #                what the UPDATE actually touched, not from the size of #rows,
    #                so the two numbers differ out loud if a row moved underneath.
    # kept_chosen  — every reference resolved and none lives in the project the chip
    #                names, so the chip cannot be inherited. Left alone.
    # undecidable  — the thread has no readable reference, or one that no longer
    #                resolves, so there is no evidence either way. Left alone,
    #                counted apart: guessing here would guess in the deleting
    #                direction for exactly the threads where the witness is missing.
    # rows         — the cleared threads, one Row each. THE record of the run: a
    #                count cannot be compared with the preview's count (the same
    #                number can be a different set), and after update_all nothing
    #                else says which chip held which project.
    Result = Struct.new(:cleared, :kept_chosen, :undecidable, :rows, keyword_init: true)

    BATCH_SIZE = 500

    # Which project a referenced object lives in, per type. One query per type and
    # batch; the pairs come back as [id, project_id].
    #
    # ⚠️ Deliberately NOT a fourth card in Assistant::ReferenceRegistry, which §2.3
    # of the plan warns against by name. This is a ONE-OFF sweep for S2, and a
    # field on Entry would make every future type declare something that only a
    # task which has already run would ever read. The price of keeping it here is
    # that it can fall behind the registry -- and that price is paid in full by
    # #ensure_registry_is_mapped!, which refuses the whole run while a registered
    # type is missing. Behind, but loud.
    PROJECT_ID_BY_TYPE = {
      'Ticket' => ->(ids) { Ticket.where(id: ids).pluck(:id, :project_id) },
      # The knowledge objects (doc/assistent_wissen_kontext_plan.md): mapped so
      # the guard below stays quiet, although the sweep has already run once on
      # production and found nothing (28.08.2026). Retiring the sweep is its own
      # cleanup PR; until then a registry that grows must not make it abort.
      'Note' => ->(ids) { Note.where(id: ids).pluck(:id, :project_id) },
      'Document' => ->(ids) { Document.where(id: ids).pluck(:id, :project_id) },
      'Meeting' => ->(ids) { Meeting.where(id: ids).pluck(:id, :project_id) }
    }.freeze

    def self.call(dry_run: false)
      new(dry_run: dry_run).call
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
    end

    def call
      ensure_registry_is_mapped!

      # Chats are tenant-scoped, a maintenance run is not: the operator means the
      # whole estate, and a rake task in this app usually runs with a tenant set.
      # Without this the sweep reports a clean finish having seen exactly one
      # organisation, which reads as done.
      ActsAsTenant.without_tenant do
        rows = []
        kept_chosen = 0
        undecidable = 0

        # in_batches, and the rows are collected rather than written inside the
        # loop: its cursor walks the primary key, so updating the very rows it is
        # paging over is how a batch gets skipped.
        candidates.in_batches(of: BATCH_SIZE) do |batch|
          chats = batch.to_a
          projects = reference_projects_for(chats)

          chats.each do |chat|
            case verdict(chat, projects)
            when :inherited
              rows << Row.new(chat_id: chat.id, organisation_id: chat.organisation_id,
                              project_id: chat.scope_project_id)
            when :chosen then kept_chosen += 1
            else undecidable += 1
            end
          end
        end

        # ⚠️ The order is imposed HERE, not by in_batches. Its cursor walks the
        # primary key, but the relation it yields carries no ORDER BY, so the rows
        # come back in whatever order Postgres finds them -- measured, and it was
        # neither ascending nor stable. A preview and a run that list the same
        # threads differently are worse than no list, because the operator's diff
        # then shows a change that is not there.
        rows.sort_by!(&:chat_id)

        Result.new(cleared: apply(rows), kept_chosen: kept_chosen, undecidable: undecidable, rows: rows)
      end
    end

    private

    # update_all on purpose: no acting user, nothing to validate, nothing that
    # should broadcast. It also keeps the run away from the reference validation,
    # which has no business firing on a column it does not touch.
    #
    # An empty list is `WHERE 1=0` in Rails, not `IS NULL` -- the safe direction,
    # and the opposite of the where.not trap noted at #candidates.
    def apply(rows)
      return rows.size if @dry_run

      Chat.where(id: rows.map(&:chat_id)).update_all(scope_project_id: nil)
    end

    # ⚠️ Fail closed when the registry grows. A type joins ENTRIES (as 'Meeting' did
    # in S3), and a sweep that quietly skipped what it cannot map would decide on the evidence of
    # the references it DOES understand -- for a thread whose meeting reference may
    # well be the one that wrote the chip.
    #
    # Keyed on the REGISTRY rather than on the data that happens to be present: a
    # data-dependent abort is invisible in every test run and surfaces on an
    # operator's terminal at the worst possible moment.
    def ensure_registry_is_mapped!
      unmapped = Assistant::ReferenceRegistry.types - PROJECT_ID_BY_TYPE.keys
      return if unmapped.empty?

      raise UnmappedType,
            "Chats::ScopeProjectCleanup kennt kein Projekt fuer: #{unmapped.join(', ')}. " \
            'Der Lauf entscheidet nicht auf halber Evidenz. PROJECT_ID_BY_TYPE ergaenzen ' \
            '(doc/assistent_bezug_sammlung_plan.md §10 S2).'
    end

    # :inherited — a reference lives in the project the chip names, which is exactly
    #              what the old coupling wrote
    # :chosen    — every reference resolved and none of them does
    # :undecidable — nothing readable to compare against
    def verdict(chat, projects)
      pairs = Assistant::ReferenceRegistry.stored_entries_of(chat)
      # ⚠️ Not the same as "the column is empty". #candidates counts entries RAW,
      # the registry drops malformed and unregistered ones, so a thread can pass the
      # filter and yield nothing here. That is a thread we know nothing about.
      return :undecidable if pairs.empty?

      lived_in = pairs.map { |pair| projects[Assistant::ReferenceRegistry.key_for(**pair)] }
      # compact first, and this is belt AND braces: an unresolved reference is nil
      # in this list, and matching nil against a NULL chip would read "inherited"
      # out of two absences. ⚠️ Measured inert today -- removing the compact turns
      # no example red, because #candidates already excludes a NULL chip. It is
      # kept so that the rule does not depend on a filter fifty lines away, and it
      # is labelled so nobody reads it as a tested property.
      return :inherited if lived_in.compact.include?(chat.scope_project_id)
      return :undecidable if lived_in.any?(&:nil?)

      :chosen
    end

    # The project of every reference on these threads, keyed by the registry's own
    # composite key so this sweep does not invent a second way to name a reference
    # (plan §7.1). One query per type, not one per thread.
    def reference_projects_for(chats)
      ids_by_type = Hash.new { |types, type| types[type] = [] }
      chats.each do |chat|
        Assistant::ReferenceRegistry.stored_entries_of(chat).each do |pair|
          ids_by_type[pair[:type]] << pair[:id]
        end
      end

      ids_by_type.each_with_object({}) do |(type, ids), found|
        # fetch, not [], and it cannot miss: #ensure_registry_is_mapped! has run and
        # stored_entries_of yields registered types only. If that reasoning ever
        # breaks, this raises rather than resolving the whole type to nil.
        PROJECT_ID_BY_TYPE.fetch(type).call(ids.uniq).each do |id, project_id|
          found[Assistant::ReferenceRegistry.key_for(type: type, id: id)] = project_id
        end
      end
    end

    # Org threads that carry references AND a project. Three conditions, three
    # reasons:
    #   * org_threads -- scope_project_id is a property of the org-wide personal
    #     thread (S3a T5). Since projekt_chat_abbau that is every thread, and the
    #     scope stays as the term the caller asks.
    #   * a non-empty list -- the precondition for the question; #verdict decides it.
    #   * a project set -- so the reported number is the number of threads that
    #     actually changed, not the number that matched a pattern.
    #
    # ⚠️ jsonb_array_length and NOT `where.not(scope_references: [])`. An ARRAY
    # value in a Rails condition means IN, so that reads as `1=0`, and negated as
    # `1=1`: the sweep would have cleared the project of EVERY thread in the
    # estate, references or not. Measured -- the cell that caught it is the one
    # that keeps an untouched neighbour beside the cleared thread.
    def candidates
      Chat.org_threads.where.not(scope_project_id: nil)
          .where('jsonb_array_length(scope_references) > 0')
    end
  end
end
