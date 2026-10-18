# frozen_string_literal: true

# The company in the product screenshots of the project website: Nordlicht Software GmbH, Kiel, six
# people, two clients. Everything here is invented. Addresses use nordlicht.example
# (RFC 2606, never deliverable), avatars are initials, and no name belongs to a real
# person we know of. Before a new set of pictures goes to the website, every name in
# this file goes through script/leak_guard.
#
# Each text exists in German and English, because the pictures for /en show the
# English interface, and an English interface around German ticket titles would look
# like a product made for Germany only.
#
# Writes go through the paths a real instance uses where those paths decide what the
# page shows (Projects::DefaultAttributeService for status and priority,
# Actors::SaveTicket for the ticket numbers), and through factories everywhere else,
# like the system specs.
module NordlichtFiction
  # A Wednesday morning: the week columns of the time list show Monday to today.
  NOW = Time.zone.local(2026, 10, 14, 10, 30)

  DOMAIN = 'nordlicht.example'

  PEOPLE = {
    svenja: { first_name: 'Svenja', last_name: 'Brandt' },  # project lead, signed in
    jana: { first_name: 'Jana', last_name: 'Petersen' },    # managing director
    malte: { first_name: 'Malte', last_name: 'Hansen' },    # development
    ole: { first_name: 'Ole', last_name: 'Jensen' },        # development
    lena: { first_name: 'Lena', last_name: 'Thiel' },       # design
    finn: { first_name: 'Finn', last_name: 'Carstensen' }   # support
  }.freeze

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

  # Minutes per person and day, relative to NOW, on the ticket at that index.
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

  NOTES = [
    { de: 'Abnahmeprotokoll Mieterportal', en: 'Acceptance record tenant portal',
      content: {
        de: '<p>Abnahme mit Deichblick Immobilien am 6. Oktober, im Büro Kiel.</p>' \
            '<p><strong>Abgenommen</strong></p>' \
            '<ul><li>Anmeldung mit Einmalcode</li><li>Dokumente je Objekt</li>' \
            '<li>Postfach für Mieter</li></ul>' \
            '<p><strong>Offen</strong></p>' \
            '<ul><li>Schadensmeldung mit Fotos, Abnahme nach dem Test mit drei Hausmeistern</li>' \
            '<li>PDF-Export der Nebenkostenabrechnung, Termin Ende Oktober</li></ul>' \
            '<p>Nächster Termin: 28. Oktober.</p>',
        en: '<p>Acceptance with Deichblick Immobilien on 6 October, at the Kiel office.</p>' \
            '<p><strong>Accepted</strong></p>' \
            '<ul><li>Sign-in with a one-time code</li><li>Documents per property</li>' \
            '<li>Inbox for tenants</li></ul>' \
            '<p><strong>Open</strong></p>' \
            '<ul><li>Damage report with photos, accepted after the test with three caretakers</li>' \
            '<li>PDF export of the service charge statement, due end of October</li></ul>' \
            '<p>Next meeting: 28 October.</p>'
      } },
    { de: 'Wie wir mit Deichblick abrechnen', en: 'How we bill Deichblick',
      content: { de: 'Monatlich nach Aufwand, Stundensatz laut Rahmenvertrag, Rechnung bis zum Dritten.',
                 en: 'Monthly by effort, hourly rate per framework agreement, invoice by the third.' } },
    { de: 'Server und Zugänge', en: 'Servers and access',
      content: { de: 'Staging und Produktion bei Deichblick, Zugang über VPN. Ansprechpartner im Kundenportal.',
                 en: 'Staging and production at Deichblick, access via VPN. Contacts in the client portal.' } }
  ].freeze

  # Comments on the ticket of the detail motif, oldest first, hours before NOW.
  COMMENTS = [
    { person: :svenja, hours_ago: 26,
      de: 'Deichblick braucht die Summen je Objekt und je Mieter, nicht nur je Objekt.',
      en: 'Deichblick needs the totals per property and per tenant, not only per property.' },
    { person: :ole, hours_ago: 2,
      de: 'Summenzeile steht, Mieter-Ebene ist drin. Morgen die Vorlage mit dem Logo von Deichblick.',
      en: 'Totals row is done, tenant level is in. Tomorrow the template with the Deichblick logo.' }
  ].freeze

  # The assistant motif: one question, one answer citing a ticket, the hours on it and
  # a note. [1] to [3] are the inline links to the citations, in the order of
  # NordlichtWorld#add_chat. The answer is stored, not generated; it has to be one the
  # product really gives (checked against a real run before a new set of pictures).
  CHAT = {
    question: { de: 'Wie weit ist die Nebenkostenabrechnung für Deichblick?',
                en: 'How far along is the service charge statement for Deichblick?' },
    answer: {
      de: 'Der PDF-Export der Nebenkostenabrechnung ist in Bearbeitung [1]. Ole hat diese Woche ' \
          '4:30 Stunden darauf gebucht, zuletzt heute an der Summenzeile [2]. Laut Abnahmeprotokoll ' \
          'vom 6. Oktober sind Anmeldung, Dokumente und Postfach abgenommen, die Schadensmeldung ist ' \
          'noch offen [3].',
      en: 'The PDF export of the service charge statement is in progress [1]. Ole has booked ' \
          '4:30 hours on it this week, most recently today on the totals row [2]. According to the ' \
          'acceptance record of 6 October, sign-in, documents and inbox are accepted; the damage ' \
          'report is still open [3].'
    },
    ticket: 3,
    note: 0
  }.freeze

  module_function

  def text(entry, locale) = entry.fetch(locale)

  # The sidebar shows the part before the @, so the address carries the full name.
  def email(key)
    person = PEOPLE.fetch(key)
    "#{I18n.transliterate(person[:first_name]).downcase}.#{I18n.transliterate(person[:last_name]).downcase}@#{DOMAIN}"
  end
end
