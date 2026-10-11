# frozen_string_literal: true

module Docs
  # Hand-curated map from a page's semantic context (the `context_type` already
  # carried by NeoProjectLayoutHeaderComponent, or an explicit key elsewhere) to
  # a short list of common questions, each deep-linking into the Hilfe surface.
  # Centralized rather than inlined per view (doc/kontexthilfe_plan.md, D2) so
  # every slug and anchor can be validated against the real rendered content in
  # ONE pass. That pass is no longer here: the text moved to
  # gboyke/lalabase-documentation, and `rake anchors:check` over there resolves
  # all of them (this repository's own spec now only checks the map's shape,
  # because the recorded catalogue it would read is a two-page example).
  # Redcarpet's heading-id slugification is not always
  # intuitive (e.g. "Status ändern" -> "status-ndern", umlauts are dropped, not
  # transliterated) AND differs PER LOCALE (headings are translated, so DE and
  # EN anchors for the "same" heading are different strings) — `anchor:` is
  # therefore a `{ de:, en: }` hash, never a single shared string.
  module ContextualHelp
    QUESTIONS = {
      tickets: [
        { label_key: 'docs.contextual_help.tickets.change_view',
          slug: 'guides/ticket-views/configure-view' },
        { label_key: 'docs.contextual_help.tickets.assign_or_watch',
          slug: 'guides/ticket-views/assign-status',
          anchor: { de: 'ticket-beobachten-ohne-zugewiesen-zu-sein',
                    en: 'follow-a-ticket-without-being-assigned' } },
        { label_key: 'docs.contextual_help.tickets.custom_fields',
          slug: 'guides/ticket-views/custom-fields-tags',
          anchor: { de: 'ticket-felder', en: 'ticket-fields' } }
      ],
      knowledge: [
        { label_key: 'docs.contextual_help.knowledge.organize_notes',
          slug: 'guides/knowledge/organize-notes' },
        { label_key: 'docs.contextual_help.knowledge.versioning',
          slug: 'guides/knowledge/versioning' }
      ],
      chat: [
        { label_key: 'docs.contextual_help.chat.what_can_it_see',
          slug: 'guides/ai/assistant' },
        { label_key: 'docs.contextual_help.chat.repository_context',
          slug: 'guides/repositories/use-in-chat' }
      ],
      inbox: [
        { label_key: 'docs.contextual_help.inbox.how_it_works',
          slug: 'guides/inbox/notifications' },
        { label_key: 'docs.contextual_help.inbox.what_reaches_me',
          slug: 'guides/inbox/notifications',
          anchor: { de: 'einstellen-was-dich-erreicht', en: 'choosing-what-reaches-you' } }
      ],
      dashboard: [
        { label_key: 'docs.contextual_help.dashboard.customize_overview',
          slug: 'guides/dashboards/cockpit-overview',
          anchor: { de: 'die-bersicht-anpassen', en: 'customizing-the-overview' } },
        { label_key: 'docs.contextual_help.dashboard.cockpit_vs_overview',
          slug: 'guides/dashboards/cockpit-overview',
          anchor: { de: 'das-cockpit-ber-alle-organisationen', en: 'the-cockpit-across-organisations' } }
      ],
      time_sessions: [
        { label_key: 'docs.contextual_help.time_sessions.what_and_where',
          slug: 'guides/features/time-tracking',
          anchor: { de: 'zeit-erfassen', en: 'tracking-time' } },
        { label_key: 'docs.contextual_help.time_sessions.filter_review',
          slug: 'guides/features/time-tracking',
          anchor: { de: 'auswerten', en: 'reviewing' } },
        { label_key: 'docs.contextual_help.time_sessions.what_is_billing',
          slug: 'guides/billing/bill-time' },
        { label_key: 'docs.contextual_help.time_sessions.partial_billing',
          slug: 'guides/billing/bill-time',
          anchor: { de: 'teilabrechnungen-am-ticket-erkennen',
                    en: 'spotting-partial-billing-on-a-ticket' } }
      ],
      billing: [
        { label_key: 'docs.contextual_help.billing.what_is_it',
          slug: 'guides/billing/bill-time' },
        { label_key: 'docs.contextual_help.billing.prepare_export',
          slug: 'guides/billing/bill-time',
          anchor: { de: 'aufbereiten-und-exportieren', en: 'prepare-and-export' } },
        { label_key: 'docs.contextual_help.billing.mark_billed',
          slug: 'guides/billing/bill-time',
          anchor: { de: 'als-abgerechnet-markieren', en: 'mark-as-billed' } }
      ],
      meetings: [
        { label_key: 'docs.contextual_help.meetings.what_is_it',
          slug: 'guides/meetings/basics' },
        { label_key: 'docs.contextual_help.meetings.capture',
          slug: 'guides/meetings/basics',
          anchor: { de: 'ein-meeting-anlegen', en: 'creating-a-meeting' } },
        { label_key: 'docs.contextual_help.meetings.external_participant',
          slug: 'guides/meetings/external-participants',
          anchor: { de: 'interne-und-externe-teilnehmer',
                    en: 'internal-and-external-participants' } },
        { label_key: 'docs.contextual_help.meetings.what_is_linking',
          slug: 'guides/meetings/external-participants',
          anchor: { de: 'was-beim-verkn-pfen-passiert',
                    en: 'what-happens-when-you-link' } },
        { label_key: 'docs.contextual_help.meetings.analyses',
          slug: 'guides/meetings/ki-analysen',
          anchor: { de: 'im-assistenten-analysieren', en: 'analyse-in-the-assistant' } }
      ],
      documentation: [
        { label_key: 'docs.contextual_help.documentation.what_is_it',
          slug: 'guides/documentation/write-and-sync' },
        { label_key: 'docs.contextual_help.documentation.stays_current',
          slug: 'guides/documentation/write-and-sync',
          anchor: { de: 'automatisch-aktuell-gehalten',
                    en: 'kept-up-to-date-automatically' } },
        { label_key: 'docs.contextual_help.documentation.search_and_chat',
          slug: 'guides/documentation/write-and-sync',
          anchor: { de: 'suche-und-chat', en: 'search-and-chat' } }
      ],
      # --- Organisations-Verwaltung: one context per settings tab
      #     (doc/settings_kontexthilfe_plan.md). Keys mirror the subnav `active:` symbols. ---
      settings_members: [
        { label_key: 'docs.contextual_help.settings_members.what_is_it',
          slug: 'guides/team/invite-members' },
        { label_key: 'docs.contextual_help.settings_members.project_access',
          slug: 'guides/team/project-access' }
      ],
      settings_roles: [
        { label_key: 'docs.contextual_help.settings_roles.what_is_a_role',
          slug: 'guides/team/roles-permissions' },
        { label_key: 'docs.contextual_help.settings_roles.create_role',
          slug: 'guides/team/roles-permissions',
          anchor: { de: 'rolle-anlegen', en: 'create-a-role' } },
        { label_key: 'docs.contextual_help.settings_roles.default_role',
          slug: 'guides/team/roles-permissions',
          anchor: { de: 'standard-rolle-festlegen', en: 'set-a-default-role' } }
      ],
      settings_general: [
        { label_key: 'docs.contextual_help.settings_general.what_is_org',
          slug: 'guides/basics/organisation' },
        { label_key: 'docs.contextual_help.settings_general.rename',
          slug: 'guides/basics/organisation',
          anchor: { de: 'namen-der-organisation-anpassen', en: 'renaming-your-organisation' } }
      ],
      settings_ai_provider: [
        { label_key: 'docs.contextual_help.settings_ai_provider.what_is_byok',
          slug: 'guides/ai/byok' },
        { label_key: 'docs.contextual_help.settings_ai_provider.enable_disable',
          slug: 'guides/ai/enable-disable' }
      ],
      settings_ai_sync: [
        { label_key: 'docs.contextual_help.settings_ai_sync.what_for',
          slug: 'guides/ai/sync-status' },
        { label_key: 'docs.contextual_help.settings_ai_sync.reprocess',
          slug: 'guides/ai/sync-status',
          anchor: { de: 'ausstehende-inhalte-nachverarbeiten', en: 'reprocessing-pending-content' } },
        { label_key: 'docs.contextual_help.settings_ai_sync.states',
          slug: 'guides/ai/sync-status',
          anchor: { de: 'verarbeitet-ausstehend-fehler', en: 'processed-pending-errors' } }
      ],
      settings_prompt_personas: [
        { label_key: 'docs.contextual_help.settings_prompt_personas.what_is_it',
          slug: 'guides/ai/chat-personas' },
        { label_key: 'docs.contextual_help.settings_prompt_personas.override',
          slug: 'guides/ai/chat-personas',
          anchor: { de: 'globale-vorlagen-und-eigene-personas',
                    en: 'global-templates-and-your-own-personas' } },
        { label_key: 'docs.contextual_help.settings_prompt_personas.create',
          slug: 'guides/ai/chat-personas',
          anchor: { de: 'eine-eigene-persona-anlegen', en: 'creating-your-own-persona' } }
      ],
      settings_import: [
        { label_key: 'docs.contextual_help.settings_import.what',
          slug: 'guides/import/codebasehq' },
        { label_key: 'docs.contextual_help.settings_import.order',
          slug: 'guides/import/codebasehq',
          anchor: { de: 'reihenfolge-des-imports', en: 'order-of-the-import' } },
        { label_key: 'docs.contextual_help.settings_import.undo',
          slug: 'guides/import/codebasehq',
          anchor: { de: 'einen-import-wieder-entfernen', en: 'removing-an-import-again' } }
      ],
      settings_appearance: [
        { label_key: 'docs.contextual_help.settings_appearance.accent_color',
          slug: 'guides/appearance/org-color' },
        { label_key: 'docs.contextual_help.settings_appearance.light_dark',
          slug: 'guides/appearance/switch-mode' }
      ],
      # Account form (devise/registrations/edit) — the screen people reach when
      # the confirmation banner puzzles them, or when a changed e-mail address
      # seems not to take effect (reconfirmable keeps the old one until the link
      # is clicked, which reads as a bug until somebody explains it).
      account: [
        { label_key: 'docs.contextual_help.account.why_confirm',
          slug: 'guides/basics/confirm-email',
          anchor: { de: 'warum-berhaupt-best-tigen', en: 'why-confirm-at-all' } },
        { label_key: 'docs.contextual_help.account.no_mail',
          slug: 'guides/basics/confirm-email',
          anchor: { de: 'keine-mail-bekommen', en: 'no-email-arrived' } },
        { label_key: 'docs.contextual_help.account.change_email',
          slug: 'guides/basics/confirm-email',
          anchor: { de: 'die-e-mail-adresse-sp-ter-ndern',
                    en: 'changing-your-email-address-later' } }
      ]
    }.freeze

    def self.for(context)
      QUESTIONS.fetch(context.to_sym, [])
    end

    # Locale-resolved help_page_path anchor param — nil if the question has none.
    def self.anchor_for(question, locale)
      question[:anchor]&.fetch(locale.to_sym, nil)
    end
  end
end
