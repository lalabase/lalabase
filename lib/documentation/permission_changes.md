# Feingranulare Projektberechtigungen und Pundit Integration

## Übersicht

In der neuesten Version haben wir das Berechtigungssystem umfassend überarbeitet:

1. Einführung feingranularer Rechte für den Zugriff auf Projektbereiche
2. Migration von `ProjectAccessService` zu Pundit `ProjectPolicy`
3. Optimierung der Berechtigungsprüfungen in Listen-Ansichten

Diese Änderungen ermöglichen eine genauere Kontrolle darüber, welche Benutzerrollen auf welche Projektbereiche zugreifen können, und verbessern die Code-Qualität und Wartbarkeit des Systems.

## Alte Berechtigungen

Bisher gab es zwei globale Projektberechtigungen:
- `read_access_all_projects`: Gewährte Lesezugriff auf alle Bereiche aller Projekte
- `write_access_all_projects`: Gewährte Schreibzugriff auf alle Bereiche aller Projekte

## Neue Berechtigungen

Die neuen bereichsspezifischen globalen Berechtigungen sind:

**Lesezugriff pro Bereich:**
- `read_access_chats_all_projects`: Lesezugriff auf alle Chat-Bereiche in allen Projekten
- `read_access_notes_all_projects`: Lesezugriff auf alle Notiz-Bereiche in allen Projekten
- `read_access_tickets_all_projects`: Lesezugriff auf alle Ticket-Bereiche in allen Projekten
- `read_access_documents_all_projects`: Lesezugriff auf alle Dokument-Bereiche in allen Projekten
- `read_access_time_tracking_all_projects`: Lesezugriff auf die Zeiterfassung in allen Projekten

**Schreibzugriff pro Bereich:**
- `write_access_chats_all_projects`: Schreibzugriff auf alle Chat-Bereiche in allen Projekten
- `write_access_notes_all_projects`: Schreibzugriff auf alle Notiz-Bereiche in allen Projekten
- `write_access_tickets_all_projects`: Schreibzugriff auf alle Ticket-Bereiche in allen Projekten
- `write_access_documents_all_projects`: Schreibzugriff auf alle Dokument-Bereiche in allen Projekten
- `write_access_time_tracking_all_projects`: Schreibzugriff auf die Zeiterfassung in allen Projekten

## Migration zu Pundit

### Vorteile der Pundit-Integration

Die Migration von `ProjectAccessService` zu Pundit `ProjectPolicy` bietet folgende Vorteile:

1. **Konsistente Autorisierung**: Ein einheitliches Framework für die gesamte Anwendung
2. **Bessere Testbarkeit**: Policy-Objekte sind einfacher zu testen als Service-Klassen
3. **Klarere Hierarchie**: Deutliche Trennung zwischen globalen und projektspezifischen Berechtigungen
4. **Einfachere Controller**: Kürzerer Code durch Verwendung von `authorize @project, :action?`
5. **Verbesserter Schutz**: Automatische Überprüfung von Berechtigungen für alle Controller-Aktionen

### Implementierte Pundit Policies

Die folgenden Policy-Klassen wurden erstellt oder aktualisiert:

1. `ApplicationPolicy`: Basisklasse für alle Policies mit gemeinsamen Methoden
2. `ProjectPolicy`: Spezifische Policy für Projekte mit den folgenden Hauptmethoden:
   - `index?`: Prüft, ob der Benutzer die Projektliste sehen darf
   - `show?`: Prüft, ob der Benutzer ein spezifisches Projekt sehen darf
   - `create?`: Prüft, ob der Benutzer neue Projekte erstellen darf
   - `update?`: Prüft, ob der Benutzer ein Projekt bearbeiten darf
   - `destroy?`: Prüft, ob der Benutzer ein Projekt löschen darf
   - `area_access?(area, action)`: Prüft den Zugriff auf einen bestimmten Projektbereich

## Berechtigungshierarchie

Die Berechtigungsprüfung erfolgt in folgender Hierarchie:

1. **Grundvoraussetzungen**: Projekt existiert, Organisation existiert, Benutzer ist aktives Mitglied
2. **Admin-Status**: Account-Admins haben immer vollen Zugriff
3. **Projektspezifische Berechtigungen**: Haben Vorrang vor globalen Berechtigungen
   - `no_access` auf Projektebene blockiert den Zugriff, selbst wenn globale Berechtigungen existieren
   - `read_only`/`read_write` auf Projektebene gewährt entsprechenden Zugriff
4. **Globale (rollenbasierte) Berechtigungen**: Greifen, wenn keine projektspezifischen Berechtigungen definiert sind

## Optimierungen für Listen-Ansichten

1. **Bedingte UI-Elemente**:
   - "Neues Projekt"-Button wird nur angezeigt, wenn der Benutzer Projekte erstellen darf
   - (Das projektbezogene Dropdown-Menü gibt es nicht mehr, siehe unten.)

> **Entfernt am 06.09.2026:** `ProjectPermissionCache` (`app/helpers/projects_helper.rb`)
> cachte Berechtigungsergebnisse pro Request für Projektlisten. Die zugehörige Liste
> gibt es seit dem Briefing-Dashboard nicht mehr, ihr letztes Zeilenmenü wurde von
> keiner View mehr gerendert, und die Klasse setzte `can_archive?`/`can_unarchive?`/
> `can_destroy?` ein zweites Mal neben `ProjectPolicy` um. Beides ist mit der Seite
> "Archivierte Objekte" gelöscht worden (doc/archivierte_objekte_plan.md). Wer wieder
> eine Projektliste baut: erst `ProjectPolicy` fragen, und einen Cache nur dann neu
> einführen, wenn eine Messung ihn verlangt.

## Migration bestehender Berechtigungen

Für bestehende Installationen wurde eine Migrationsstrategie implementiert:

```bash
rake permissions:migrate_to_granular
```

Diese Task führt die folgenden Aktionen durch:
1. Identifizierung aller Rollen mit `read_access_all_projects`
2. Erstellung der bereichsspezifischen Leseberechtigungen für diese Rollen
3. Identifizierung aller Rollen mit `write_access_all_projects`
4. Erstellung der bereichsspezifischen Schreib- und Leseberechtigungen für diese Rollen

## Best Practices

Für Entwickler, die mit diesem System arbeiten, empfehlen wir:

1. Verwenden Sie `policy(@resource).action?` oder `authorize @resource, :action?` in Controllern
2. Nutzen Sie in Views `<% if policy(@resource).action? %>` für bedingte Anzeige
3. Für Listen-Ansichten `includes` nutzen und die Policy pro Zeile fragen; einen Berechtigungs-Cache erst einführen, wenn eine Messung ihn rechtfertigt
4. Definieren Sie neue Berechtigungen in `Permission::CATEGORIES` und dokumentieren Sie diese in `RolesHelper`
5. Stellen Sie sicher, dass projektspezifische Berechtigungen immer Vorrang vor globalen haben

## Nächste Schritte

In zukünftigen Versionen werden wir möglicherweise:
1. Die Pundit-Integration auf weitere Ressourcen ausweiten (Notes, Tickets, etc.)
2. Weitere feingranulare Berechtigungen einführen
3. Ein erweitertes Caching-System für Berechtigungsprüfungen implementieren