# Neuen Changelog-Eintrag erstellen

Erstellt einen neuen Eintrag für die "Neuigkeiten"-Seite (Changelog) in `app/changelog/`.

## Ablauf

1. **Thema erfragen**
   - Frage den User nach dem Titel des Eintrags (z.B. "Neuer Ticket-Filter")
   - Frage nach einer kurzen Beschreibung des Features/der Änderung
   - Frage, ob Screenshots hinzugefügt werden sollen

2. **Slug generieren**
   - Verwende das heutige Datum im Format `YYYY-MM-DD`
   - Erzeuge einen URL-freundlichen Slug aus dem Titel (lowercase, Bindestriche, keine Umlaute/Sonderzeichen)
   - Dateiname: `YYYY-MM-DD_slug.md`

3. **Frontmatter erstellen**
   - `title`: Der Titel des Eintrags
   - `date`: Heutiges Datum im Format `YYYY-MM-DD`
   - `images`: Array der Bild-Pfade (relativ zu `app/assets/images/`, z.B. `changelog/screenshot.png`), leer wenn keine Screenshots

4. **Body schreiben**
   - Schreibe den Markdown-Body basierend auf der Beschreibung des Users
   - Halte den Text kurz und prägnant (2-5 Sätze)
   - Verwende Markdown-Formatierung (fett, Listen, Code-Blöcke) wo sinnvoll

5. **Screenshots verarbeiten** (optional)
   - Falls Screenshots angegeben wurden, prüfe ob die Dateien existieren
   - Screenshots gehören nach `app/assets/images/changelog/`
   - Trage die Pfade ins `images`-Array im Frontmatter ein

6. **Datei erstellen**
   - Speichere die Datei in `app/changelog/`
   - Zeige den fertigen Eintrag an

## Frontmatter-Format

```markdown
---
title: Neuer Ticket-Filter
date: 2026-03-02
images:
  - changelog/ticket-filter.png
---

Beschreibung hier...
```

## Beispiele

```
/new_changelog_entry
```

Erstellt interaktiv einen neuen Changelog-Eintrag mit Datum von heute.

## Hinweise

- Der `Changelog::EntryLoader` liest alle `*.md` Dateien aus `app/changelog/`
- YAML-Frontmatter mit `title`, `date` und `images` ist Pflicht
- Bilder werden mit `image_tag` gerendert, Pfade sind relativ zu `app/assets/images/`
- Der Rails-Cache invalidiert automatisch beim nächsten Request nach Dateiänderung
