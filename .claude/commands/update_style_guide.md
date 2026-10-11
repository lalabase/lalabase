# Update Style Guide Command

Dieser Command aktualisiert den Style Guide mit neuen oder geänderten Komponenten und führt automatisch ein Changelog-Update durch.

## Ablauf

1. **Parameter ermitteln**
   - Komponenten-Name (z.B. buttons, forms, smart_folders, cards)
   - Action: "new" für neue Komponenten oder "update" für Änderungen an bestehenden

2. **Versionierung**
   - Extrahiert die aktuelle Version aus dem Changelog
   - Erhöht Minor-Version für neue Komponenten (z.B. 1.3.0 → 1.4.0)
   - Erhöht Patch-Version für Updates (z.B. 1.3.0 → 1.3.1)

3. **Changelog automatisch aktualisieren**
   - Aktualisiert die "Aktuelle Version" im Changelog
   - Fügt neuen Eintrag mit Datum, Version und Badge (NEW/UPDATE) hinzu
   - Verwendet standardisierte Beschreibungen basierend auf der Komponente

4. **Navigation prüfen und aktualisieren**
   - Für neue Komponenten: Prüft ob Navigation-Links existieren
   - Zeigt Anweisungen für manuelle Navigation-Updates
   - Prüft Controller-Actions und Routes

5. **View-Template erstellen (nur neue Komponenten)**
   - Erstellt automatisch eine Style Guide Seite für neue Komponenten
   - Verwendet standardisiertes Template mit Breadcrumbs und Struktur
   - Placeholder für Live-Demos und Code-Beispiele

## Komponenten-Konfiguration

Der Command kennt bereits folgende Komponenten mit Icon und Beschreibung:

- **buttons**: Button-Komponenten mit verschiedenen Varianten
- **forms**: Formular-Komponenten und Input-Felder  
- **cards**: Card-Komponenten für strukturierte Inhalte
- **headers**: Header- und TitleBox-Komponenten
- **modals**: Modal-Dialoge und Overlays
- **tags**: Tag-Komponenten für Labels und Kategorien
- **activities**: Activity-Feed und Timeline-Komponenten
- **smart_folders**: SmartFolder Navigation-Sidebar
- **flash_messages**: Benachrichtigungen und Erfolgsmeldungen
- **drag_drop**: Drag-and-Drop-Komponenten

Für unbekannte Komponenten werden Standard-Werte generiert.

## Automatische Changelog-Einträge

Je nach Action wird automatisch ein passender Changelog-Eintrag erstellt:

### NEW Badge (grün)
- Für neue Komponenten
- Minor-Version wird erhöht
- Badge: `bg-green-100` mit "NEW"

### UPDATE Badge (blau)  
- Für Updates bestehender Komponenten
- Patch-Version wird erhöht
- Badge: `bg-blue-100` mit "UPDATE"

## Verwendung

```
/update_style_guide
```

Der Command fragt interaktiv nach:
1. Komponenten-Name (z.B. "buttons", "forms", "smart_folders")
2. Action ("new" oder "update")

Alternativ mit Parametern:
```
/update_style_guide buttons update
/update_style_guide forms new
```

## Nach dem Command

Der Command zeigt nach Abschluss die nächsten manuellen Schritte:

1. **Style Guide View anpassen**: Inhalt der generierten Template-Datei
2. **Navigation testen**: Überprüfung der Route `/style-guide/[component]`
3. **Controller-Action hinzufügen**: Falls noch nicht vorhanden
4. **Git Commit erstellen**: Alle Änderungen committen

## Beispiel-Workflow

1. Neue Cards-Komponente wurde entwickelt
2. `/update_style_guide cards new`
3. Version wird von 1.3.0 → 1.4.0 erhöht
4. Changelog-Eintrag wird automatisch erstellt
5. Template für `/app/views/style_guide/cards.html.erb` wird generiert
6. Navigation-Hinweise werden angezeigt
7. Manuelle Anpassungen der View und Navigation
8. Style Guide ist vollständig aktualisiert

## Erweiterte Features (Roadmap)

### 🚀 Nächste Version
- **Code-Beispiel-Extraktion**: Automatisches Scannen von ViewComponent-Parametern
- **Screenshot-Automation**: Playwright-basierte Visual Testing
- **Dependency-Management**: Erkennung von Komponenten-Abhängigkeiten
- **Performance-Tracking**: Bundle-Size und Render-Time-Monitoring

### 🔧 Erweiterte Parameter
```bash
# Breaking Changes mit Migration-Guide
/update_style_guide buttons update --breaking --migration="Rename 'style' to 'variant'"

# Bulk-Updates für mehrere Komponenten
/update_style_guide --bulk buttons,forms,modals --action=update

# Custom Version-Bump
/update_style_guide cards new --version=major --reason="Complete API redesign"

# Rollback-Funktionalität
/rollback_style_guide v1.4.0
```

### 📊 Quality Gates
- **Accessibility-Check**: WCAG 2.1 Compliance-Validation
- **Browser-Testing**: Cross-Browser Compatibility
- **Performance-Budget**: CSS/JS Size-Limits
- **Design-Token-Consistency**: Automatische Farb/Spacing-Validierung

## Aktuelle Vorteile

- ✅ **Konsistenz**: Einheitliche Changelog-Formatierung
- ✅ **Automatisierung**: Versionierung und Template-Erstellung
- ✅ **Vollständigkeit**: Prüfung von Navigation, Routes und Controller
- ✅ **Nachverfolgung**: Chronologische Dokumentation aller Änderungen
- ✅ **Effizienz**: Ein Command für den kompletten Update-Prozess