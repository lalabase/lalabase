# frozen_string_literal: true

# Operator entry points for the chat maintenance tasks.
#
# chats:backfill_owners and Chats::OwnerBackfill were removed by
# projekt_chat_abbau: their entire subject was the PROJECT thread (assistant plan
# §5.2 backfilled an owner onto pre-S1 project conversations, which had none), and
# production reported 0 project threads before the surface went. They were never on
# a deploy hook -- only chats:backfill_scope_references is -- so nothing schedules a
# task that no longer exists.
#
# chats:purge_legacy_threads STAYS until step 5. It is the tool that empties
# chats.project_id, and the migration that drops the column aborts loudly while a
# row still carries one.

def chats_dry_run!(task_name)
  raw = ENV['DRY_RUN'].to_s.strip.downcase
  abort "#{task_name}: DRY_RUN=#{ENV.fetch('DRY_RUN', nil)} nicht verstanden. Erlaubt: 1/true/yes oder 0/false/no." unless raw.empty? || %w[0 1 true false yes no].include?(raw)

  %w[1 true yes].include?(raw)
end

# ORGS=<name-or-uuid>[,...] → organisation ids, or nil for all.
#
# Two aborts, both for the same reason: whatever slips through here, the run deletes.
#   * An entry that matches nothing. Silently falling back to "all" is the wrong direction
#     for a deletion run, and a typo in a name looks like a match.
#   * A name carried by several organisations. `name` is not unique, and "I meant that
#     one" can no longer be said after the run. Use the UUID then.
# We only search by id when the entry LOOKS like a UUID: the column is uuid, and
# Postgres raises PG::InvalidTextRepresentation for anything else.
def chats_target_organisation_ids!(task_name)
  raw = ENV['ORGS'].to_s.strip
  return nil if raw.empty?

  ActsAsTenant.without_tenant do
    entries = raw.split(',').map(&:strip).reject(&:empty?)
    uuids = entries.select { |entry| entry.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/) }
    # ONE query, not one per entry: the Prosopite guard in the specs counts along.
    found = Organisation.where(name: entries).or(Organisation.where(id: uuids)).to_a

    ambiguous = found.group_by(&:name).select { |name, orgs| orgs.size > 1 && entries.include?(name) }.keys
    abort "#{task_name}: mehrdeutige Organisation(en), bitte UUID angeben: #{ambiguous.join(', ')}" if ambiguous.any?

    matched = found.flat_map { |org| [org.name, org.id] }
    missing = entries - matched
    abort "#{task_name}: unbekannte Organisation(en): #{missing.join(', ')}" if missing.any?

    found.map(&:id).uniq
  end
end

namespace :chats do
  desc 'Projekt-Verlaeufe loeschen (DRY_RUN=1 zeigt nur an, ORGS=... grenzt auf Organisationen ein). UNUMKEHRBAR.'
  task purge_legacy_threads: :environment do
    task_name = 'chats:purge_legacy_threads'
    # The switch has been gone since S4-T1. Swallowing it silently would mean the operator
    # makes a decision the run no longer knows about; hence loud. The message describes
    # the state this code runs in: the column is gone.
    # (The special case "new release directory against old schema" belongs to the
    # migration, not to this task.)
    if ENV.key?('INCLUDE_TICKET_THREADS')
      abort "#{task_name}: INCLUDE_TICKET_THREADS ist seit S4-T1 ohne Wirkung: Ticket-Verlaeufe " \
            'gibt es nicht mehr (Spalte entfernt), der Lauf unterscheidet sie nicht. Schalter weglassen.'
    end
    dry_run = chats_dry_run!(task_name)
    organisation_ids = chats_target_organisation_ids!(task_name)

    result = Chats::LegacyThreadPurge.call(dry_run: dry_run, organisation_ids: organisation_ids)

    puts format('%<task>s%<mode>s%<scope>s', task: task_name, mode: dry_run ? ' (DRY_RUN)' : '',
                                             scope: organisation_ids ? " ORGS=#{organisation_ids.size}" : '')
    puts format('  %<threads>d Verlaeufe mit %<posts>d Beitraegen%<verb>s geloescht',
                threads: result.threads, posts: result.posts, verb: dry_run ? ' waeren' : '')

    # Per organisation, because a deletion run spans several tenants and the operator
    # must see BEFORE the real run whose data it touches, not afterwards.
    ActsAsTenant.without_tenant do
      result.per_organisation.each do |organisation_id, count|
        puts format('    %-30<name>s %3<count>d', name: Organisation.find_by(id: organisation_id)&.name.to_s[0, 30],
                                                  count: count)
      end
    end

    if dry_run
      puts '  Vorschau, es wurde nichts geloescht.'
    elsif result.threads.zero?
      # A silent zero run reads like success. Usually it is an ORGS that is too narrow.
      puts '  Nichts geloescht: kein Verlauf passte auf den Schnitt.'
    else
      puts '  Geloescht. Rueckweg ist nur das Backup.'
    end
  end
  # Bezugs-Sammlung S2 (doc/assistent_bezug_sammlung_plan.md §10 S2): clear the
  # search scope that the reference used to write.
  #
  #   rake chats:cleanup_scope_projects DRY_RUN=1
  #   rake chats:cleanup_scope_projects
  #
  # ONCE and by hand, after the S2 deploy. The reasoning sits in the header of
  # Chats::ScopeProjectCleanup; it is the important half of this task.
  #
  # ⚠️ This task does NOT belong in Lalabase::DataBackfills, unlike
  # chats:backfill_scope_references one screen further up. The hook runs on
  # EVERY deploy, and after E3 a user may have references and a deliberately
  # chosen project at the same time: the run would wipe that choice again on
  # every following deploy. The backfill may go in the hook because its WHERE
  # CANNOT be satisfied any more after the first run; this one never becomes
  # empty. The criterion is "can the WHERE become true again", not "is it a
  # data run".
  #
  # ⚠️ What used to stand here was wrong: "the window is whoever picks a project
  # between deploy and run". The window was always the whole lifetime of the
  # feature. The chip is a free selection field and was never locked while a
  # reference was set, so threads with a reference AND a deliberately chosen
  # project existed long before this deploy. The run therefore no longer decides
  # on "carries references", but on whether the chip names the project of a
  # reference: only that could have been written by Actors::AddChatReference.
  #
  # What remains afterwards and cannot be decided: someone who deliberately chose
  # exactly the project of their reference. That is why the run prints its ROWS,
  # and the list is the only way back there is.
  desc 'Suchbereich raeumen, den der Bezug frueher mitgeschrieben hat (E3). EINMALIG, DRY_RUN=1 zeigt nur an.'
  task cleanup_scope_projects: :environment do
    task_name = 'chats:cleanup_scope_projects'
    dry_run = chats_dry_run!(task_name)
    begin
      result = Chats::ScopeProjectCleanup.call(dry_run: dry_run)
    rescue Chats::ScopeProjectCleanup::UnmappedType => e
      # No half run and no backtrace on the terminal: the sweep can no longer
      # decide, and that is a sentence, not a backtrace.
      abort "#{task_name}: #{e.message}"
    end

    puts format('%<task>s%<mode>s', task: task_name, mode: dry_run ? ' (DRY_RUN)' : '')
    puts format('  %<n>d Verlaeufe%<verb>s auf "Allen deinen Projekten" zurueckgesetzt',
                n: result.cleared, verb: dry_run ? ' wuerden' : '')
    # Always both lines, even at 0: preview and run are read side by side, and a
    # line that is sometimes there and sometimes not shifts the comparison.
    puts format('  %<n>d mit selbst gewaehltem Projekt, bleiben unangetastet', n: result.kept_chosen)
    puts format('  %<n>d ohne lesbaren Bezug, nicht entscheidbar, bleiben unangetastet', n: result.undecidable)

    # The list IS the way back: after the update_all the old value exists nowhere
    # else. Same shape and same order in both runs, so preview and result can be
    # compared.
    if result.rows.any?
      # ONE query, not one per row: the Prosopite guard counts along.
      names = ActsAsTenant.without_tenant do
        Organisation.where(id: result.rows.map(&:organisation_id).uniq).pluck(:id, :name).to_h
      end
      puts '  Betroffen (Organisation, Verlauf, bisheriges Projekt):'
      result.rows.each do |row|
        puts format('    %-30<org>s %<chat>s  %<project>s',
                    org: names[row.organisation_id].to_s[0, 30], chat: row.chat_id, project: row.project_id)
      end
    end

    if dry_run
      puts '  Vorschau, es wurde nichts geschrieben.'
    elsif result.cleared.zero?
      # A silent zero run reads like success. Here it usually means: the run has
      # already happened once, and that is the normal case the second time.
      puts '  Nichts geraeumt: kein Verlauf trug einen geerbten Suchbereich.'
    else
      puts '  Geraeumt. Rueckweg ist die Liste oben: scope_project_id je Verlauf ' \
           'wieder auf das genannte Projekt setzen.'
      puts '  Ein zweiter Lauf findet nichts mehr, solange niemand auf einem ' \
           'Verlauf mit Bezuegen bewusst das Projekt eines seiner Bezuege waehlt. ' \
           'Ab dann wuerde er diese Wahl loeschen: nicht wiederholen.'
    end
  end

  # Bezugs-Sammlung S1 (doc/assistent_bezug_sammlung_plan.md §4.3): MOVE the old
  # single reference into the new list.
  #
  # Listed in Lalabase::DataBackfills, so it runs on EVERY deploy on the primary
  # DB host, with the freshly shipped code and BEFORE the restart. Therefore:
  #   * once via the SOURCE: the statement empties scope_ticket_id in the same
  #     step in which it fills the list, and never hits a row again afterwards,
  #   * ONE statement, no service and no batch: a column copy is not row logic,
  #     the OwnerBackfill pattern would be too heavy for it,
  #   * raw SQL, because the source column no longer exists on the Ruby side
  #     (Chat.ignored_columns) but very much does in the database.
  #
  # ⚠️ Move, do not copy, and that is the lesson from the review of this slice:
  # a copy with a WHERE on the empty TARGET becomes true again as soon as a user
  # removes the reference under new code (list [] again, source still filled
  # because nobody touches it any more), and the next deploy would bring the
  # removed reference back, without scope_project_id, so with a chip that claims
  # something other than the actual reach. "Idempotent against itself" is not
  # "idempotent against user intent".
  #
  # Rollback of this slice: old code reads scope_ticket_id, finds NULL, and the
  # moved references are INVISIBLE, not lost; scope_references carries them, a
  # redeploy shows them again. Whatever gets newly set under old code, the next
  # run picks up. The column is only cleared in the follow-up PR, and the entry in
  # Lalabase::DataBackfills::TASKS goes in the SAME delivery as the column
  # (pinned as data in the spec). If it stays, the backfills run right after the
  # migration against a column that no longer exists: the deploy aborts and
  # leaves the old code standing against the new schema.
  #
  # The remaining window is the seconds between hook and restart. A reference
  # that old code sets on a thread without references in that window, the next
  # run picks up; a change or removal on a thread that was just moved is lost in
  # those seconds, because the list is already filled then and the WHERE no
  # longer matches.
  desc 'Einzelbezug (alte Spalte) in die Bezugs-Sammlung verschieben. Einmalig je Zeile, DRY_RUN=1 zaehlt nur.'
  task backfill_scope_references: :environment do
    task_name = 'chats:backfill_scope_references'
    dry_run = chats_dry_run!(task_name)

    where = "scope_ticket_id IS NOT NULL AND scope_references = '[]'"

    if dry_run
      pending = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM chats WHERE #{where}")
      puts "#{task_name} (DRY_RUN): #{pending} Verlaeufe wuerden einen Bezug bekommen."
    else
      result = ActiveRecord::Base.connection.execute(<<~SQL.squish)
        UPDATE chats
           SET scope_references = jsonb_build_array(
                 jsonb_build_object('type', 'Ticket', 'id', scope_ticket_id)
               ),
               scope_ticket_id = NULL
         WHERE #{where}
      SQL
      puts "#{task_name}: #{result.cmd_tuples} Verlaeufe haben einen Bezug bekommen."
    end
  end
end
