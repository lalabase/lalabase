# Karte: app/services/notifications (Stand: 2026-11-13, S2b)

Verarbeitet OutboxEvents zu Notifications. Die Gesamtkette (Trackable → Activity → OutboxEvent →
OutboxConsumeJob → hier) ist kartiert in `docs/architektur/seiteneffekt_ketten.md`.

* **Einstieg: `fanout_service.rb`** (~535 LOC) — bestimmt, WER eine Notification bekommt.
  **DUAL-PATH:** Tickets = subscription-basiert (`NotificationSubscription` + User-Settings-Filter),
  Non-Tickets (Project/Document/Note/…) = score-basiert. Änderungen an Empfänger-Regeln
  müssen IMMER beide Pfade prüfen.
* `score_calculator.rb` — Prioritäts-Score (nur Non-Ticket-Pfad)
* `suppressor.rb` — unterdrückt Duplikate/Selbst-Benachrichtigung
* `group_key_builder.rb` — Notification-Gruppierung (`find_or_create_group`)
* `broadcast_service.rb` — In-App-Zustellung via Turbo Streams. Das Banner „Neue Meldungen“
  (`notifications/_new_notifications_banner`, geteilt mit der Gesamt-Inbox) ERSETZT den leeren
  Platzhalter, in der Sprache des Empfängers; bis 13.11.2026 landete der Text im versteckten
  Platzhalter und war nie zu sehen.
* `streams.rb` — die Turbo-Stream-Namen (`user:<id>:org:<org_id>:badge|notifications`).
  Sender und Abonnenten bauen den Namen NUR hier; ein Name ohne Organisation ließ bis
  29.09.2026 den Inbox-Zähler von Org B in einer offenen Seite von Org A erscheinen.
  **Ein dritter Name ohne Organisation** (seit S2a): `all_inboxes(user)`, nur für die
  Gesamt-Inbox. Auf ihm geht nur ein Stempel, nie eine Zahl, ein Titel oder eine Organisation;
  keine Seite einer Organisation abonniert ihn (`spec/requests/all_inboxes_live_spec.rb`).
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
* **Die Inbox über den Organisationen** („Gesamt-Inbox“, `GET /inbox`, `AllInboxesController`,
  seit 13.11.2026): dieselbe Liste wie die Inbox einer Organisation, mit der Reichweite der
  Person (`PersonalAccessToken::Reach.for_person`). Sie liest über `InboxQuery.reading`, filtert
  und blättert mit `Inbox::MasterListPresenter` und zeichnet mit den Partials von
  `organisations/notifications/` (ein Schalter: `InboxHelper#inbox_above_organisations?`).
  ⚠️ Die Seite hat keinen Mandanten: alles, was eine Zeile zeigt, wird im Block von `reading`
  geladen (`presenter.load!`), ein später nachgeladener Verweis wirft `NoTenantSet`. Sie setzt
  die Organisation der Sitzung nie; der Filter heißt deshalb `org` und nicht `organisation_id`
  (daraus liest `ApplicationController#load_tenant_from_session` den Mandanten). Eine Zeile
  führt in die Inbox ihrer Organisation; eine eigene Bahn hat die Seite noch nicht. **Live (S2a):** `UnreadSignals.call` sendet nach den Punkten des Umschalters
  ein Signal auf `Streams.all_inboxes`: nur `InboxQuery.stamp` (HMAC über geordnete
  Fingerprints jeder In-App-Zeile in Reichweite, inklusive Zustand und Änderungszeit).
  Ein Maximum pro Zustand übersieht ältere Schreibvorgänge, die später committen.
  Die Seite zeichnet denselben Stempel
  mit ihrer Liste; weicht das Signal ab, holt sie die Zahlen (`GET /inbox` als turbo_stream,
  `part=counts`) und zeigt das Banner, die Liste bewegt sich erst auf dessen Wort
  (`all_inboxes_live_controller`). `load_list` liest Stempel, Zahlen und Zeilen in einer
  Repeatable-Read-Transaktion; die Request-Specs verwenden deshalb `:real_transactions`.
  Der Auslöser im Modell ist dafür breiter als „ungelesen
  ja/nein“: jede neue Zeile, jeder Wechsel zwischen ungelesen, gelesen und archiviert, ein neues
  Ereignis einer Gruppe (`last_event_at`), jedes Löschen. **Aktionen an der Zeile** (gelesen, ungelesen, archivieren, zurückholen) haben
  eigene Adressen (`PATCH /inbox/:id/...`), weil jede Adresse unter `/org/:id` die Organisation
  der Sitzung umstellt. Die Zeile findet `InboxQuery.row` (eigene, in Reichweite, sichtbar,
  sonst 404), Policy und Schreiben laufen unter dem Mandanten der ZEILE. Geschrieben wird über
  `Actors::ChangeNotificationState`, denselben Actor wie in der Inbox einer Organisation: er
  nimmt die übrigen Meldungen zum selben Gegenstand mit (ein Ticket = eine Zeile), außer bei
  „ungelesen“. Der Listenzustand reist in der Adresse der Aktion mit, nicht im Referrer.
  **Sammelaktionen (S2b):** die Leiste der Organisations-Inbox, auf eigenen Adressen
  (`PATCH /inbox/selection/{mark_read,archive}`, in `routes.rb` VOR dem `:id`-Scope der Zeile).
  Nur eine Auswahl: ohne IDs 422, die Seite kennt kein „alles“; über
  `AllInboxesController::MAX_SELECTION` (500) ebenfalls 422. Die Zeilen findet
  `selection.rb` (`Notifications::Selection`) OHNE `without_tenant`: je aktive Organisation der
  Person unter `with_tenant` der Policy-Scope der Meldungen (was dort keine eigene, sichtbare
  In-App-Zeile ist, fällt wortlos weg, die übrige Auswahl wird geändert). Der ganze Weg der
  Sammelaktion vom Finden bis zum Schreiben bleibt damit im Mandanten; das Lesen der LISTE
  (`InboxQuery.reading`, `.stamp`, `.row`) hebt ihn noch auf. Die
  Policy wird unter dem Mandanten jeder berührten Organisation gefragt. Geschrieben wird über
  `Actors::ChangeNotificationStates`, denselben Actor wie der IDs-Pfad der Leiste in einer
  Organisation: eine Transaktion über alle Organisationen, in der Reihenfolge ihrer IDs, je
  unter `with_tenant`; „gelesen“ ändert nur Ungelesenes, „archivieren“ nur, was nicht im Archiv
  liegt, ein wiederholter Request ändert also nichts. **Was eine Zeile mitnimmt und wie gesperrt
  wird, steht einmal** in `subject_bundle.rb` (`Notifications::SubjectBundle`: sichtbare
  In-App-Meldungen zum selben Gegenstand, EINE Sperr-Anweisung in ID-Reihenfolge), für den
  Zeilen- und den Sammel-Actor. Die Antwort nennt die Zahl der gefundenen ZEILEN (ein Ticket
  zählt einmal) im Flash der Seite (`#flash`). Die Rückfrage vor einer Aktion über mehrere
  Organisationen stellt der Browser (`inbox_bulk_select_controller`), der Server verlangt sie
  nicht. ⚠️ Der Pfad OHNE IDs in einer Organisation (Glocken-Dropdown, ganze Inbox) und
  `Api::V1::NotificationsController#mark_all_as_read` schreiben weiter selbst über
  `bulk_transition!`, ohne Bündel und ohne Sperre.
  Wächter: `spec/requests/all_inboxes_spec.rb`, `spec/requests/all_inboxes_row_actions_spec.rb`,
  `spec/requests/all_inboxes_bulk_actions_spec.rb`,
  `spec/services/actors/change_notification_states_spec.rb` (auch `_concurrency_spec.rb`),
  `spec/services/notifications/selection_spec.rb`,
  `spec/requests/all_inboxes_live_spec.rb`, `spec/services/notifications/inbox_query_stamp_spec.rb`,
  `spec/system/all_inboxes_spec.rb`.
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
