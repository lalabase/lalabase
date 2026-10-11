# frozen_string_literal: true

module Lalabase
  # The idempotent data backfills that run after the schema migrations on every
  # deploy. `rake lalabase:data_backfills` runs them in order; our Capistrano
  # deploy and bin/docker-entrypoint both call it, so a backfill listed here
  # reaches every installation, ours and the self-hosted ones.
  #
  # A backfill belongs here when it changes data, not schema (JSONB config, a
  # value moved into a new column), and only if it is idempotent: it runs on
  # EVERY deploy and must touch nothing the second time. A task whose condition
  # can become true again must never be listed (chats:cleanup_scope_projects,
  # see Chats::ScopeProjectCleanup).
  #
  # Entry point: TASKS, run by lib/tasks/data_backfills.rake.
  module DataBackfills
    TASKS = [
      # Projects created before the Backlog status get it; new projects have it
      # from Projects::DefaultAttributeService. Can go once no installation is
      # older than the Backlog feature.
      'tickets:add_backlog_status',
      # ⚠️ MOVES chats.scope_ticket_id into chats.scope_references and empties the
      # source in the same statement. It reads a column the Ruby side no longer
      # knows (Chat.ignored_columns), so this entry has to go in the SAME release
      # that drops the column: left standing, it would run right after the
      # migration against a deleted column. Pinned as data in
      # spec/lib/tasks/chats_backfill_scope_references_spec.rb.
      'chats:backfill_scope_references',
      # Removes stored role permissions whose action left Permission::CATEGORIES
      # (the Prozesse rights, October 2026). Idempotent, and it stays: the next
      # removed right needs no task of its own.
      'permissions:prune_unknown_actions',
      # Notifications of tickets moved before Tickets::Mover took them along
      # (2026-10-07) move to their ticket's project, so the inbox rule measures
      # them against the right project. Idempotent, and it may stay: it only
      # ever aligns.
      'notifications:align_ticket_projects',
      # Notifications a deleted project left behind with an empty project_id
      # (ProjectDeletionJob until 2026-10-08) go: a row without a project passes
      # the inbox rule as a system message. A row with a mail log stays (bounces).
      # Idempotent, and it may stay: it only deletes rows whose subject is gone.
      'notifications:purge_project_leftovers'
    ].freeze
  end
end
