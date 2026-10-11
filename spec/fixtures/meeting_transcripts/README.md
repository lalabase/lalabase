# Meeting-Parser Spike-Fixtures (synthetisch, repo-tauglich)

Diese Fixtures sind **vollständig synthetisch** — erfundene Personen und eine bewusst
fachfremde, fiktive Domäne (Kleingartenverein „Sonnenwinkel": Sommerfest, Wasserleitung,
Kassenbericht), damit kein Inhalt echten Gesprächen ähnelt. Sie dürfen ins Repo
(z. B. `spec/fixtures/meeting_transcripts/`).

Die **Format-Muster** stammen aus einem Zensus über ein lokales Korpus echter
Transkripte (23 Stück, Stand 2026-07-11). Die echten Dateien enthalten Kunden-PII
und sind bewusst NICHT Teil des Repos.

## Format-Familie (empirisch belegt)

- Sprecherzeile: `**Label:**` am Zeilenanfang (Markdown-Bold), danach Fließtext.
- **Zweite Familie:** dieselbe Zeile OHNE Bold (`Label:`) — kommt vor, wenn das
  Transkriptionswerkzeug die Sprecher unausgezeichnet ausgibt. Der Offline-Parser
  greift dort nicht (er verlangt `**`), die Teilnehmer kommen dann über den LLM-Weg.
  `Meetings::SpeakerMarkup` zeichnet diese Zeilen beim RENDERN aus, geprüft gegen die
  Teilnehmerliste des Meetings statt per Heuristik (Fixture 06).
- Label-Varianten (alle real beobachtet, hier mit den synthetischen Namen notiert):
  1. Nur Vorname: `**Anna:**`
  2. Voller Name: `**Anna Ananas:**`
  3. Diarisierungs-Suffix: `**Karl Krause (Speaker 2):**`, `**Bert Bauer (Speaker 3):**`
  4. Gruppen-Label: `**Alle:**`
- **Dieselbe Person unter bis zu 4 Labels** im selben Korpus (Vorname / voller Name /
  verschiedene Speaker-Nummern) → Normalisierung ist Pflicht, nicht Kür.
- **Umlaut-Transliteration derselben Person** (z. B. `ü` ↔ `ue`) ist im echten Korpus
  belegt, im Fixture-Set aber aktuell NICHT abgedeckt — die drei Fixture-Namen sind
  bewusst umlautfrei. Bei Bedarf ein sechstes Fixture mit Umlaut-Namen ergänzen.
- Mehr-Absatz-Turns: Folgeabsätze OHNE Label gehören zum vorherigen Sprecher.
- Optionaler YAML-Frontmatter + `# Transkript:`-Überschrift (fällt beim Copy-Paste
  ggf. weg → Parser darf beides nicht voraussetzen).
- KEINE strukturellen Timestamps, kein VTT/SRT. Uhrzeiten („um 10:00 Uhr") kommen
  nur als Gesprächsinhalt vor → dürfen nicht als Struktur gelesen werden.

## Fixtures + erwartete Teilnehmer (Ground Truth für die Quoten-Messung)

Besetzung (konsistent über alle Fixtures): **Anna Ananas** = Erste Vorsitzende,
**Bert Bauer** = Platzwart, **Karl Krause** = Kassenwart.

| Fixture | Testet | Erwartete Teilnehmer (normalisiert) |
|---|---|---|
| `fixture_01_vollnamen_frontmatter.md` | Standardfall: Frontmatter + volle Namen + Mehr-Absatz-Turn | Anna Ananas, Bert Bauer, Karl Krause |
| `fixture_02_vornamen_ohne_frontmatter.md` | Roher Paste-Body, nur Vornamen | Anna, Bert, Karl |
| `fixture_03_speaker_suffixe.md` | Diarisierungs-Suffixe `(Speaker N)` + `**Alle:**` (kein Teilnehmer!) | Karl Krause, Anna Ananas, Bert Bauer |
| `fixture_04_namens_normalisierung.md` | Dieselbe Person unter 3 Labels: `Karl` / `Karl Krause` / `Karl Krause (Speaker 2)` → EIN Teilnehmer | Karl Krause, Bert Bauer, Anna Ananas |
| `fixture_05_fallstricke.md` | False-Positives: `**Wichtig:**`/`**Fazit:**`, Uhrzeiten, URLs/Doppelpunkte im Text, Sprecherzeile am Dateiende ohne Newline | Bert Bauer, Karl Krause |
| `fixture_06_unmarkierte_sprecher.md` | Sprecherzeilen OHNE `**`-Auszeichnung (zweite reale Format-Familie), inkl. Suffix `(?)`. Für `Meetings::SpeakerMarkup`, NICHT für die Parser-Quotenmessung | Anna, Karl, Bert Bauer |

**Messregel-Vorschlag für den Spike:** Precision und Recall pro Fixture gegen die
Tabelle; `Alle`, `Wichtig`, `Fazit` etc. als erkannter „Teilnehmer" = False Positive.
