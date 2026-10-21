# frozen_string_literal: true

module Lalabase
  module Demo
    # The invented company of the product screenshots and the public demo: Nordlicht
    # Software GmbH, Kiel, six people, two clients. Everything here is invented.
    # Addresses use nordlicht.example (RFC 2606, never deliverable), avatars are
    # initials, and no name belongs to a real person we know of. Before a new set of
    # pictures goes to the website, every name in this file goes through
    # script/leak_guard.
    #
    # Each text exists in German and English, because the pictures for /en show the
    # English interface, and an English interface around German ticket titles would
    # look like a product made for Germany only.
    #
    # Times are relative (days, hours ago), so the same world can be built at a frozen
    # moment for the pictures and at the moment of a reset for the demo. A date inside
    # a text is a placeholder that Lalabase::Demo::World fills in from that moment.
    module Fiction
      DOMAIN = 'nordlicht.example'

      PEOPLE = {
        svenja: { first_name: 'Svenja', last_name: 'Brandt' },  # project lead, signed in
        jana: { first_name: 'Jana', last_name: 'Petersen' },    # managing director, account admin
        malte: { first_name: 'Malte', last_name: 'Hansen' },    # development
        ole: { first_name: 'Ole', last_name: 'Jensen' },        # development
        lena: { first_name: 'Lena', last_name: 'Thiel' },       # design
        finn: { first_name: 'Finn', last_name: 'Carstensen' }   # support
      }.freeze

      # The owner of the organisation. Everybody else, the signed-in person included,
      # holds the team role: a visitor of the demo is never an account admin.
      OWNER = :jana
      SIGNED_IN = :svenja

      ALL_PROJECTS = %w[chats notes meetings tickets documents time_tracking].flat_map do |area|
        ["read_access_#{area}_all_projects", "write_access_#{area}_all_projects"]
      end.freeze

      # Read and write in every project, the assistant, and names in full. What a small
      # agency gives its whole team.
      TEAM_ROLE = {
        title: { de: 'Team', en: 'Team' },
        description: { de: 'Arbeitet in allen Projekten mit', en: 'Works in every project' },
        permissions: {
          'projects' => %w[change_project_properties create_new_projects read_access_documentation_all_projects] +
                        ALL_PROJECTS,
          'users' => %w[view_user_full_name view_user_contact_details],
          'assistant' => %w[use_assistant]
        }
      }.freeze

      # Every member of the team works in every project, as on the project permissions
      # page. The project lead also sees and corrects everybody's hours.
      PROJECT_ACCESS = { tickets_access: :read_write, notes_access: :read_write, documents_access: :read_write,
                         chats_access: :read_write, meetings_access: :read_write,
                         documentation_access: :read_only, members_access: :read_only }.freeze
      LEAD_TIME_RIGHTS = { can_view_all: true, can_edit_all: true }.freeze

      PROJECTS = {
        deichblick: { de: 'Deichblick Kundenportal', en: 'Deichblick client portal',
                      description: { de: 'Objektverwaltung für Deichblick Immobilien.',
                                     en: 'Property management for Deichblick Immobilien.' } },
        faehrhaus: { de: 'Fährhaus Tourenplanung', en: 'Fährhaus route planning',
                     description: { de: 'Tourenplanung für Fährhaus Logistik.',
                                    en: 'Route planning for Fährhaus Logistik.' } },
        intern: { de: 'Nordlicht intern', en: 'Nordlicht internal',
                  description: { de: 'Eigene Website und Abläufe.', en: 'Our own website and processes.' } }
      }.freeze

      # Oldest first: the numbers follow the order of creation.
      TICKETS = [
        { de: 'Anmeldung mit Einmalcode für Mieter', en: 'One-time code sign-in for tenants',
          status: 'resolved', priority: 'high', assignee: :malte },
        { de: 'Mieterportal: Dokumente nach Objekt sortieren', en: 'Tenant portal: sort documents by property',
          status: 'resolved', priority: 'normal', assignee: :ole },
        { de: 'Schadensmeldung mit Fotos', en: 'Damage report with photos',
          status: 'in_progress', priority: 'high', assignee: :malte },
        { de: 'Nebenkostenabrechnung als PDF exportieren', en: 'Export the service charge statement as PDF',
          status: 'in_progress', priority: 'urgent', assignee: :ole },
        { de: 'Entwürfe für die Objektübersicht', en: 'Designs for the property overview',
          status: 'in_progress', priority: 'normal', assignee: :lena },
        { de: 'Login-Fehler bei Umlauten im Passwort', en: 'Login fails with umlauts in the password',
          status: 'new', priority: 'urgent', assignee: :finn },
        { de: 'Hausmeister-Rolle mit Lesezugriff', en: 'Caretaker role with read access',
          status: 'new', priority: 'normal', assignee: :malte },
        { de: 'Erinnerung vor Ablauf der Wartungsverträge', en: 'Reminder before maintenance contracts expire',
          status: 'backlog', priority: 'low', assignee: nil },
        { de: 'Schnittstelle zur Buchhaltung klären', en: 'Clarify the interface to accounting',
          status: 'backlog', priority: 'normal', assignee: :svenja }
      ].freeze

      # Minutes per person and day, on the ticket at that index. All of it falls in the
      # week of the build (World#booked_on): CHAT[:answer] sums Ole's week.
      TIME = [
        { person: :malte, days_ago: 0, minutes: 150, ticket: 2,
          de: 'Upload der Fotos, Vorschau', en: 'Photo upload, preview' },
        { person: :ole, days_ago: 0, minutes: 90, ticket: 3,
          de: 'PDF-Vorlage, Summenzeile', en: 'PDF template, totals row' },
        { person: :lena, days_ago: 1, minutes: 240, ticket: 4,
          de: 'Objektübersicht, zweiter Entwurf', en: 'Property overview, second draft' },
        { person: :malte, days_ago: 1, minutes: 210, ticket: 2,
          de: 'Schadensmeldung: Formular und Prüfung', en: 'Damage report: form and validation' },
        { person: :svenja, days_ago: 1, minutes: 60, ticket: nil,
          de: 'Abstimmung mit Deichblick', en: 'Call with Deichblick' },
        { person: :ole, days_ago: 2, minutes: 180, ticket: 3,
          de: 'Datenabfrage für die Abrechnung', en: 'Query for the statement' },
        { person: :finn, days_ago: 2, minutes: 45, ticket: 5,
          de: 'Fehler nachgestellt', en: 'Reproduced the error' }
      ].freeze

      # The dates a text names, in days from the moment the world is built, and how a
      # date reads inside a sentence.
      DATES = { accepted_on: -8, next_meeting_on: 14 }.freeze
      DATE_FORMAT = { de: '%-d. %B', en: '%-d %B' }.freeze

      NOTES = [
        { de: 'Abnahmeprotokoll Mieterportal', en: 'Acceptance record tenant portal',
          content: {
            de: '<p>Abnahme mit Deichblick Immobilien am %<accepted_on>s, im Büro Kiel.</p>' \
                '<p><strong>Abgenommen</strong></p>' \
                '<ul><li>Anmeldung mit Einmalcode</li><li>Dokumente je Objekt</li>' \
                '<li>Postfach für Mieter</li></ul>' \
                '<p><strong>Offen</strong></p>' \
                '<ul><li>Schadensmeldung mit Fotos, Abnahme nach dem Test mit drei Hausmeistern</li>' \
                '<li>PDF-Export der Nebenkostenabrechnung, Termin Ende des Monats</li></ul>' \
                '<p>Nächster Termin: %<next_meeting_on>s.</p>',
            en: '<p>Acceptance with Deichblick Immobilien on %<accepted_on>s, at the Kiel office.</p>' \
                '<p><strong>Accepted</strong></p>' \
                '<ul><li>Sign-in with a one-time code</li><li>Documents per property</li>' \
                '<li>Inbox for tenants</li></ul>' \
                '<p><strong>Open</strong></p>' \
                '<ul><li>Damage report with photos, accepted after the test with three caretakers</li>' \
                '<li>PDF export of the service charge statement, due at the end of the month</li></ul>' \
                '<p>Next meeting: %<next_meeting_on>s.</p>'
          } },
        { de: 'Wie wir mit Deichblick abrechnen', en: 'How we bill Deichblick',
          content: { de: 'Monatlich nach Aufwand, Stundensatz laut Rahmenvertrag, Rechnung bis zum Dritten.',
                     en: 'Monthly by effort, hourly rate per framework agreement, invoice by the third.' } },
        { de: 'Server und Zugänge', en: 'Servers and access',
          content: { de: 'Staging und Produktion bei Deichblick, Zugang über VPN. Ansprechpartner im Kundenportal.',
                     en: 'Staging and production at Deichblick, access via VPN. Contacts in the client portal.' } }
      ].freeze

      # Comments on the ticket of the detail motif, oldest first.
      COMMENTS = [
        { person: :svenja, hours_ago: 26,
          de: 'Deichblick braucht die Summen je Objekt und je Mieter, nicht nur je Objekt.',
          en: 'Deichblick needs the totals per property and per tenant, not only per property.' },
        { person: :ole, hours_ago: 2,
          de: 'Summenzeile steht, Mieter-Ebene ist drin. Morgen die Vorlage mit dem Logo von Deichblick.',
          en: 'Totals row is done, tenant level is in. Tomorrow the template with the Deichblick logo.' }
      ].freeze

      # Two meetings. The first comes with its summary, the second without one, so a
      # visitor of the demo can let the assistant write it. Speakers in a transcript
      # carry the display name of a participant; guests have no account.
      MEETINGS = [
        { project: :deichblick, days_ago: 2, minutes: 30,
          title: { de: 'Wochentermin mit Deichblick', en: 'Weekly call with Deichblick' },
          participants: [:svenja, :ole, 'Kerstin Möller'],
          transcript: {
            de: <<~TEXT,
              Svenja Brandt: Kurzer Stand zur Nebenkostenabrechnung. Ole, wie weit bist du?
              Ole Jensen: Der PDF-Export läuft, die Summenzeile steht. Die Summen je Mieter baue ich gerade ein.
              Kerstin Möller: Das ist wichtig für uns. Die Mieter fragen jedes Jahr nach ihrem eigenen Anteil.
              Ole Jensen: Dann kommt pro Mieter eine eigene Seite. Brauchen Sie das Logo von Deichblick oben?
              Kerstin Möller: Ja, bitte. Ich schicke es heute noch als Vektordatei.
              Svenja Brandt: Und die Schadensmeldung?
              Kerstin Möller: Die testen drei Hausmeister ab Montag. Danach können wir sie abnehmen.
              Svenja Brandt: Gut. Dann sehen wir uns zur Abnahme in zwei Wochen.
            TEXT
            en: <<~TEXT
              Svenja Brandt: Quick update on the service charge statement. Ole, how far are you?
              Ole Jensen: The PDF export works and the totals row is done. I am adding the totals per tenant now.
              Kerstin Möller: That matters to us. Tenants ask for their own share every year.
              Ole Jensen: Then each tenant gets a page of their own. Do you need the Deichblick logo at the top?
              Kerstin Möller: Yes, please. I will send it today as a vector file.
              Svenja Brandt: And the damage report?
              Kerstin Möller: Three caretakers test it from Monday. After that we can accept it.
              Svenja Brandt: Good. Then we meet for the acceptance in two weeks.
            TEXT
          },
          summary: {
            de: <<~TEXT,
              **Nebenkostenabrechnung:** PDF-Export und Summenzeile fertig. Jeder Mieter bekommt eine eigene Seite mit seinem Anteil.

              **Schadensmeldung:** Drei Hausmeister testen ab Montag, danach Abnahme.

              **Aufgaben**
              - Kerstin Möller schickt das Logo als Vektordatei.
              - Ole Jensen baut die Seite je Mieter mit Logo.
              - Abnahmetermin in zwei Wochen.
            TEXT
            en: <<~TEXT
              **Service charge statement:** PDF export and totals row are done. Each tenant gets a page of their own with their share.

              **Damage report:** Three caretakers test it from Monday, acceptance afterwards.

              **Action items**
              - Kerstin Möller sends the logo as a vector file.
              - Ole Jensen builds the page per tenant, with the logo.
              - Acceptance meeting in two weeks.
            TEXT
          } },
        { project: :faehrhaus, days_ago: 1, minutes: 45,
          title: { de: 'Kick-off Tourenplanung', en: 'Kick-off route planning' },
          participants: [:jana, :svenja, :malte, 'Tobias Reimers'],
          transcript: {
            de: <<~TEXT,
              Jana Petersen: Willkommen zum Kick-off. Tobias, erzähl kurz, was heute nicht funktioniert.
              Tobias Reimers: Wir planen 14 Fahrer mit einer Tabelle. Jede Änderung am Morgen kostet uns eine Stunde.
              Malte Hansen: Woher kommen die Aufträge? Per Mail, per Telefon, aus einem System?
              Tobias Reimers: Zwei Drittel aus unserem Warenwirtschaftssystem, der Rest per Telefon.
              Malte Hansen: Dann lesen wir die Aufträge aus der Warenwirtschaft und erfassen den Rest von Hand.
              Svenja Brandt: Für den ersten Schritt reicht eine Tagesansicht pro Fahrer, die man umsortieren kann.
              Tobias Reimers: Wichtig ist, dass die Fahrer die Tour auf dem Handy sehen.
              Jana Petersen: Dann nehmen wir das in den ersten Meilenstein. Svenja schickt bis Freitag ein Angebot.
            TEXT
            en: <<~TEXT
              Jana Petersen: Welcome to the kick-off. Tobias, tell us briefly what does not work today.
              Tobias Reimers: We plan 14 drivers in a spreadsheet. Every change in the morning costs us an hour.
              Malte Hansen: Where do the orders come from? Email, phone, another system?
              Tobias Reimers: Two thirds from our inventory system, the rest by phone.
              Malte Hansen: Then we read the orders from the inventory system and enter the rest by hand.
              Svenja Brandt: For the first step a day view per driver that can be reordered is enough.
              Tobias Reimers: What matters is that the drivers see their route on their phone.
              Jana Petersen: Then that goes into the first milestone. Svenja sends a proposal by Friday.
            TEXT
          },
          summary: nil }
      ].freeze

      # The assistant motif: one question, one answer citing a ticket, the hours on it
      # and a note. [1] to [3] are the inline links to the citations, in the order of
      # Lalabase::Demo::World#add_chat. The answer is stored, not generated; it has to
      # be one the product really gives (checked against a real run before a new set
      # of pictures).
      CHAT = {
        question: { de: 'Wie weit ist die Nebenkostenabrechnung für Deichblick?',
                    en: 'How far along is the service charge statement for Deichblick?' },
        answer: {
          de: 'Der PDF-Export der Nebenkostenabrechnung ist in Bearbeitung [1]. Ole hat diese Woche ' \
              '4:30 Stunden darauf gebucht, zuletzt heute an der Summenzeile [2]. Laut Abnahmeprotokoll ' \
              'vom %<accepted_on>s sind Anmeldung, Dokumente und Postfach abgenommen, die Schadensmeldung ist ' \
              'noch offen [3].',
          en: 'The PDF export of the service charge statement is in progress [1]. Ole has booked ' \
              '4:30 hours on it this week, most recently today on the totals row [2]. According to the ' \
              'acceptance record of %<accepted_on>s, sign-in, documents and inbox are accepted; the damage ' \
              'report is still open [3].'
        },
        ticket: 3,
        note: 0,
        model: 'mistral-medium-latest'
      }.freeze

      # Asked from the ticket of the detail motif, with the ticket as its reference
      # (Chat#scope_references): the picture beside the open ticket. Cites the ticket,
      # Ole's last comment (COMMENTS) and the weekly call (MEETINGS). Same rule as CHAT:
      # stored, and checked against a real run before a new set of pictures.
      TICKET_QUESTION = {
        question: { de: 'Was ist an diesem Ticket noch offen, und wer arbeitet daran?',
                    en: 'What is still open on this ticket, and who is working on it?' },
        answer: {
          de: 'Ole Jensen arbeitet daran, die Priorität ist dringend [1]. Summenzeile und Mieter-Ebene ' \
              'stehen; offen ist die Vorlage mit dem Logo von Deichblick, die Ole morgen angeht [2]. ' \
              'Im Wochentermin hat Deichblick eine eigene Seite je Mieter gewünscht, das Logo schickt ' \
              'Kerstin Möller als Vektordatei [3].',
          en: 'Ole Jensen is working on it, and it is marked urgent [1]. The totals row and the tenant ' \
              'level are done; still open is the template with the Deichblick logo, which Ole plans for ' \
              'tomorrow [2]. In the weekly call Deichblick asked for a page per tenant, and Kerstin Möller ' \
              'sends the logo as a vector file [3].'
        },
        ticket: 3,
        meeting: 0,
        model: 'mistral-medium-latest'
      }.freeze

      # Asked from the weekly call, with the meeting as its reference. Cites the
      # meeting and the ticket the call was about. Same rule as CHAT.
      MEETING_QUESTION = {
        question: { de: 'Was haben wir in diesem Termin vereinbart, und was sind die nächsten Schritte?',
                    en: 'What did we agree in this meeting, and what are the next steps?' },
        answer: {
          de: 'Jeder Mieter bekommt in der Nebenkostenabrechnung eine eigene Seite mit seinem Anteil, oben ' \
              'mit dem Logo von Deichblick [1]. Nächste Schritte: Kerstin Möller schickt das Logo als ' \
              'Vektordatei, Ole Jensen baut die Seite je Mieter, und drei Hausmeister testen die ' \
              'Schadensmeldung ab Montag [1]. Die Abnahme ist in zwei Wochen geplant; der PDF-Export ist ' \
              'noch in Bearbeitung [2].',
          en: 'Each tenant gets a page of their own in the service charge statement, with their share and ' \
              'the Deichblick logo at the top [1]. Next steps: Kerstin Möller sends the logo as a vector ' \
              'file, Ole Jensen builds the page per tenant, and three caretakers test the damage report ' \
              'from Monday [1]. The acceptance is planned in two weeks; the PDF export is still in ' \
              'progress [2].'
        },
        meeting: 0,
        ticket: 3,
        model: 'mistral-medium-latest'
      }.freeze

      module_function

      # The sidebar shows the part before the @, so the address carries the full name.
      def email(key)
        person = PEOPLE.fetch(key)
        "#{I18n.transliterate(person[:first_name]).downcase}.#{I18n.transliterate(person[:last_name]).downcase}@#{DOMAIN}"
      end

      def full_name(key) = PEOPLE.fetch(key).values_at(:first_name, :last_name).join(' ')

      # Fills the date placeholders of a text, seen from `now`.
      def dated(text, locale, now)
        dates = DATES.transform_values do |days|
          I18n.l((now + days.days).to_date, format: DATE_FORMAT.fetch(locale), locale: locale)
        end
        format(text, **dates)
      end
    end
  end
end
