# frozen_string_literal: true

# Tier-1 actor: seeds the onboarding tutorial project ("Lalabase kennenlernen")
# for a freshly self-registered organisation (doc/onboarding_plan.md, S1).
#
# Actor split (decision D11b):
#
#   Registration (current_user = new user)
#        │
#        ▼
#   ┌───────────────────────────────────────────────┐
#   │ perform (one transaction, with_tenant(org))   │
#   │                                               │
#   │  Actor context: USER (via BaseActor)          │
#   │   ├─ create project (system_kind=onboarding)  │
#   │   ├─ default attributes (status/prio/due)     │
#   │   └─ tutorial tickets (creator: user          │
#   │      → subscribed via auto_subscribe_creator) │
#   │                                               │
#   │  Actor context: SYSTEM ACCOUNT (only here,    │
#   │  via with_actor_context(User.system))         │
#   │   └─ assignment via TicketAssignmentSync      │
#   │      (skip_email) → 'assigned' activity with  │
#   │      foreign actor → fanout creates the       │
#   │      in_app inbox notification                │
#   └───────────────────────────────────────────────┘
#
# The CONTENT belongs to the user (creator/owner — survives future
# membership assumptions, subscriptions point at a real mailbox); ONLY the
# assignment runs as the system account, because a self-action would be
# swallowed by the fanout (actor is removed from the recipient set).
#
# Idempotent via projects.system_kind: a retry or double submit finds the
# existing project and returns it unchanged. Content files are v1-frozen —
# edits to db/seeds/onboarding/* only affect newly seeded organisations.
module Actors
  class SeedOnboarding < BaseActor
    PROJECT_SYSTEM_KIND = 'onboarding'
    CONTENT_DIR = 'db/seeds/onboarding'
    CONTENT_LOCALES = %w[de en].freeze
    FALLBACK_LOCALE = 'de'
    # Single source: the default status the provisioning service seeds as the
    # first (= de-facto default) option — no duplicated string to drift.
    INITIAL_STATUS = Projects::DefaultAttributeService::DEFAULT_STATUS_VALUE

    def initialize(organisation:, current_user:)
      super()
      @organisation = organisation
      @current_user = current_user
    end

    def record
      @project
    end

    def perform
      ActsAsTenant.with_tenant(@organisation) do
        # Idempotency guard: a retry / double submit reuses the existing project.
        @project = existing_project
        next if @project.present?

        content = load_content
        @project = create_project(content.fetch('project'))
        Projects::DefaultAttributeService.new(@project).call
        tickets = create_tutorial_tickets(content.fetch('tickets'))
        assign_to_user_as_system(tickets)
      end
    end

    private

    def existing_project
      @organisation.projects.find_by(system_kind: PROJECT_SYSTEM_KIND)
    end

    def create_project(project_content)
      @organisation.projects.create!(
        name: project_content.fetch('name'),
        description: project_content['description'],
        system_kind: PROJECT_SYSTEM_KIND
      )
    end

    # Created in the new user's actor context (set by BaseActor): the user is
    # creator, auto_subscribe_creator subscribes HIM, and the 'created'
    # activities carry him as actor.
    def create_tutorial_tickets(ticket_contents)
      ticket_contents.map do |ticket_content|
        @project.tickets.create!(
          title: ticket_content.fetch('title'),
          content: ticket_content['description'],
          creator: @current_user,
          custom_attributes: { 'status' => INITIAL_STATUS }
        )
      end
    end

    # The ONLY step that runs as the system account: the assignment activity
    # needs a foreign actor, otherwise the fanout drops the recipient
    # (self-action). skip_email keeps the resulting notification in_app-only
    # (no assignment mails right after signup).
    def assign_to_user_as_system(tickets)
      with_actor_context(User.system) do
        tickets.each do |ticket|
          TicketAssignmentSync.call(
            ticket: ticket,
            assignee_ids: [@current_user.id],
            is_new_ticket: true,
            extra_activity_parameters: { 'skip_email' => true }
          )
        end
      end
    end

    # Content lives in db/seeds/onboarding/{de,en}.yml — deliberately NOT in
    # the UI locale files (multi-paragraph tutorial prose would bloat them and
    # mix two reasons to change; decision D6). Loaded per user locale with a
    # hard fallback to German.
    def load_content
      locale = @current_user.language_preference
      locale = FALLBACK_LOCALE unless CONTENT_LOCALES.include?(locale)
      YAML.safe_load_file(Rails.root.join(CONTENT_DIR, "#{locale}.yml"))
    end
  end
end
