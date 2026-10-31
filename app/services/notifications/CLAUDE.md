# Karte: app/services/notifications (Stand: 2026-10-31)

Verarbeitet OutboxEvents zu Notifications. Die Gesamtkette (Trackable → Activity → OutboxEvent →
OutboxConsumeJob → hier) ist kartiert in `docs/architektur/seiteneffekt_ketten.md`.

* **Einstieg: `fanout_service.rb`** (~535 LOC) — bestimmt, WER eine Notification bekommt.
  **DUAL-PATH:** Tickets = subscription-basiert (`NotificationSubscription` + User-Settings-Filter),
  Non-Tickets (Project/Document/Note/…) = score-basiert. Änderungen an Empfänger-Regeln
  müssen IMMER beide Pfade prüfen.
* `score_calculator.rb` — Prioritäts-Score (nur Non-Ticket-Pfad)
* `suppressor.rb` — unterdrückt Duplikate/Selbst-Benachrichtigung
* `group_key_builder.rb` — Notification-Gruppierung (`find_or_create_group`)
* `broadcast_service.rb` — In-App-Zustellung via Turbo Streams
* `streams.rb` — die Turbo-Stream-Namen (`user:<id>:org:<org_id>:badge|notifications`).
  Sender und Abonnenten bauen den Namen NUR hier; ein Name ohne Organisation ließ bis
  29.09.2026 den Inbox-Zähler von Org B in einer offenen Seite von Org A erscheinen.
* `unread_signals.rb` + `app/jobs/notifications/unread_signals_job.rb` — der Punkt am
  Org-Umschalter: ungelesene Meldungen in den ANDEREN Organisationen, gezählt nach
  derselben Regel wie die Inbox (`Notification.inbox_unread`, auch hinter
  `User#unread_notifications_count`). Bis 29.09.2026 zählten nur Erwähnungen und
  Zuweisungen, und das Menü zeigte eine kleinere Zahl als die Inbox nach dem Wechsel
  (Desktop, bewusst nicht mobil). Live je Organisation eine eigene Fassung auf deren
  Badge-Stream. Ausgelöst von den Callbacks in `notification.rb` (`after_save` merkt,
  `after_commit` löst aus, damit ein zweites Speichern in derselben Transaktion nichts
  verschluckt) und von `Notification.bulk_transition!`. Der Job läuft je Nutzer seriell
  (`limits_concurrency`), sonst überschreibt ein älterer Lauf den neueren Stand. Treffer
  jenseits von `NavigationHelper::ORG_MENU_LIMIT` zählen an „Alle Organisationen“.
* `inbox_query.rb`: die Inbox über einen Zugangstoken (API und MCP), über mehrere
  Organisationen in einer Abfrage. Welche Zeilen zählen, fragt sie `Notification.readable`
  je Organisation, wie jede andere Zählstelle (über `accessible_for`). `meta.by_organisation`
  (seit 02.10.2026) teilt `unread_total` je Organisation auf, Nullen inklusive, nach Namen;
  mit einem Token für alle Organisationen sind das die Cockpit-Kacheln. `organisation_id`
  (seit 07.10.2026) und `project_id` engen Liste und alle Zahlen ein; was nicht erreichbar
  ist, wirft `NotReachable` mit derselben Antwort wie etwas, das es nicht gibt.
* **Eine Zählregel für „ungelesen in Organisation X“** (seit 02.10.2026): Cockpit-Kachel,
  Badge, mobile Navigation, Glocken-Dropdown, Org-Umschalter, Inbox-Liste und Token-Inbox
  zählen nach `Notification.inbox_unread` / `Notification.readable` (aktive Projekte, die die
  Person lesen darf, plus projektlose Zeilen). **Seit 07.10.2026 je Bereich:** eine Meldung
  zu einem Ticket, einer Notiz oder einem Dokument zählt nur, solange die Person diesen
  Bereich lesen darf (`Notification::AREA_BY_NOTIFIABLE_TYPE`, eine Zuordnung auch für den
  Fanout, `gated_area_for`). **Seit 08.10.2026 auch Meldungen ZUM PROJEKT** (verschobenes
  Ticket, Sammeländerung, neue Notiz, neues Meeting, neues Mitglied): sie zählen im Bereich
  ihres EREIGNISSES, `payload['action']` über `Activities::AreaRegistry`
  (`Notification.area_for(notifiable, action:)`, `.project_actions_by_area`). Projektnachrichten
  (`project.updated` usw.) gelten für jeden Bereich, ein Ereignis ohne Regel für niemanden.
  Bis dahin galt eine Projekt-Meldung fürs ganze Projekt, und jedes Mitglied (beim Beitritt
  automatisch Abonnent) las Titel und Nummer verschobener Tickets über die Token-Inbox.
  Alles andere am ganzen Projekt. ⚠️ Eine Zeile OHNE Projekt gilt als Systemmeldung und
  passiert immer: darum löscht `ProjectDeletionJob` die Meldungen eines gelöschten Projekts
  (seit 08.10.2026, vorher leerte er nur `project_id`, und Verstecktes kam zurück), und der
  Backfill `notifications:purge_project_leftovers` räumt die alten Reste. Ausnahme: eine
  E-Mail-Zeile mit Mail-Log bleibt ohne Projekt, denn ein späterer Bounce oder eine
  Spam-Beschwerde findet die Person nur über sie (`EmailWebhookProcessorJob`,
  `EmailLog#check_and_disable_notifications`). Sie ist unsichtbar, weil JEDER Inbox-Leser
  auf `channel_in_app` filtert: ein neuer Leser ohne diesen Filter würde sie zeigen. Wächter: `area_rights_spec.rb`,
  `fanout_service_area_gate_spec.rb`, `project_event_area_spec.rb`,
  `spec/requests/api/project_event_notifications_spec.rb`. **Wen ein Projekt-Ereignis
  erreicht** (seit 31.10.2026, davor wegen eines nicht existierenden Bereichs nur
  Abonnenten): jeden, der den Bereich des Ereignisses lesen darf, Kontoadmins und Rollen mit
  Recht auf alle Projekte eingeschlossen, dazu die Abonnenten; Projektnachrichten jeden mit
  irgendeinem Recht im Projekt (`Project#users_with_any_access`). Die Suche kennt kein
  `rescue`: schlägt sie fehl, schlägt das Ereignis fehl. Das gilt für jeden Lauf:
  `OutboxEvent#process!` rollt einen Fehlschlag ganz zurück und plant danach neu, der Retry
  beginnt also bei null (Wächter `spec/models/outbox_event_failed_run_spec.rb`).
  Abschalten geht je Ereignistyp in den Einstellungen, stumm bleibt ein Abo im Modus
  `mute`. ⚠️ Für diese Empfänger ist das nur die Inbox: eine Mail geht ab Score 80 sofort
  raus, und ohne Abo erreicht kein Projekt-Ereignis diese Zahl. Dafür ist `project.created`
  ein `project_announcement` und kein `system_message` (Grundwert 80). Ein neues Ereignis
  gehört in die Tabelle von `fanout_service_project_event_recipients_spec.rb`. **Jeder Leser** (Liste, Zahl,
  Badge, Punkt) geht über `inbox_unread` / `accessible_for` / `policy_scope`, nie über ein
  nacktes `user.notifications` oder `Notification.where`: erzwungen von
  `spec/architecture/notification_read_guard_spec.rb` (Ausnahmeliste mit Anzahl je Datei,
  darf nur schrumpfen). Bis 07.10.2026 lasen acht Stellen an der Regel vorbei. Bis dahin vier Regeln: die Kachel ließ
  archivierte Projekte weg, Badge und Token-Inbox nicht, Navigation und Dropdown fragten gar
  nicht. Wächter: `spec/services/notifications/unread_count_parity_spec.rb`. Eine neue
  Zählstelle gehört dort als Beispiel hinein. Die Projektmenge wird **einmal je Anfrage**
  aufgelöst, je Bereich (`Current.notification_source_projects`); ein Spec, der den Zugang mitten im
  Beispiel ändert und neu zählt, spielt die zweite Anfrage mit `Current.reset` nach.
* `update_preferences_service.rb`, `index_outcome_notifier.rb`, `shared/scope_filter.rb`

Wichtig:
1. Event-Typen/Mapping leben in `app/models/concerns/notifications/constants.rb` — in
   Jobs/Services immer vollqualifiziert zugreifen (`Notifications::Constants::…`, Thread-Safety).
2. E-Mail-Zustellung hängt hinten dran: `EmailDeliveryJob` → `notification_mailer.rb` → `email_log`.
3. User-Präferenz-Checks laufen über die User-Fassaden (`app/models/user/notification_settings.rb`,
   via `delegate` in `user.rb`) — Hot-Path, Signaturen nicht ohne Fanout-Check ändern.
4. Test-Falle: `after_create_commit`-Fanout feuert in Request-Specs unzuverlässig —
   Fanout-Verhalten direkt über den Service testen, nicht über den Callback-Umweg.
5. **Sammeländerungen am Status nur über `Notification.bulk_transition!`**, nie über ein
   nacktes `update_all(state: …)`: `update_all` überspringt den `after_commit`, und der Punkt
   am Org-Umschalter bliebe bis zum Neuladen falsch. Wächter:
   `spec/models/notification_bulk_transition_guard_spec.rb`.
