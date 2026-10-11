# Create Commit Command

Dieser Command analysiert die aktuellen Änderungen im Git-Repository und erstellt automatisch einen Commit mit einer intelligenten, kurzen und prägnanten Commit-Message.

## Ablauf

1. **Repository-Status analysieren**
   - Prüft `git status` für unverfolgte und geänderte Dateien
   - Analysiert `git diff --staged` und `git diff` für Änderungen
   - Erkennt Art und Umfang der Änderungen

2. **Intelligente Message-Generierung**
   - Analysiert geänderte Dateien und deren Pfade
   - Erkennt Patterns (Controller, Views, Models, Components, etc.)
   - Identifiziert Ändeungstypen (feat, fix, refactor, docs, style, test)
   - Generiert kurze, prägnante Beschreibung

3. **Commit-Erstellung**
   - Staged alle relevanten Änderungen automatisch
   - Erstellt Commit mit generierter Message
   - Folgt Conventional Commits Standard

## Message-Generierung Logik

### Prefixes basierend auf Datei-Patterns:
- **feat:** Neue Features (neue Controller, Views, Components)
- **fix:** Bugfixes (oft erkennbar an Dateinamen oder kleinen Änderungen)
- **refactor:** Code-Verbesserungen ohne neue Features
- **docs:** Dokumentation (README, .md Dateien, Kommentare)
- **style:** UI/CSS Änderungen (ViewComponents, SCSS, Templates)
- **test:** Test-Dateien (spec/, test/)
- **chore:** Konfiguration, Dependencies (Gemfile, package.json)

### Scope-Erkennung:
- **components:** ViewComponents (neo_*_component.rb/erb)
- **tickets:** Ticket-bezogene Dateien
- **timesessions:** TimeSession-Module
- **smartfolders:** SmartFolder-Funktionalität
- **styleguide:** Style Guide Dateien
- **admin:** Admin-Interface
- **auth:** Authentication/Authorization

### Beispiel-Messages:
- `feat(components): add NeoTagComponent with variants`
- `fix(tickets): resolve pagination URL object bug`
- `refactor(timesessions): improve group assignment logic`
- `style(styleguide): update dashboard cards design`
- `docs(api): add endpoint documentation`

## Intelligente Erkennungen

### Neue Dateien:
- Erkennt neue Components, Controller, Views automatisch
- Generiert "add [ComponentName]" Messages

### Geänderte Dateien:
- Kleine Änderungen → "fix" oder "improve"
- Große Umstrukturierungen → "refactor"
- UI-Änderungen → "style" oder "update"

### Spezielle Cases:
- Migration-Dateien → "feat(db): add [table/field]"
- Route-Änderungen → "feat(routes): add [resource] endpoints"
- Gemfile → "chore: update dependencies"
- Tests → "test: add [feature] specs"

## Verwendung

```
/create_commit
```

Der Command:
1. Analysiert automatisch alle Änderungen
2. Generiert passende Commit-Message
3. Zeigt Preview der Message zur Bestätigung
4. Erstellt den Commit

Optional mit eigener Message:
```
/create_commit "custom message"
```

## Beispiel-Workflow

```bash
# Dateien wurden geändert
git status
# modified: app/components/neo_button_component.rb
# new file: app/views/style_guide/buttons.html.erb
# modified: app/views/style_guide/changelog.html.erb

# Command ausführen
/create_commit

# Generiert automatisch:
# "feat(styleguide): add button component documentation"

# Commit wird erstellt mit allen relevanten Dateien
```

## Vorteile

- ✅ **Konsistenz**: Einheitlicher Commit-Message-Stil
- ✅ **Zeitersparnis**: Keine manuellen Messages mehr schreiben
- ✅ **Conventional Commits**: Standard-konforme Messages
- ✅ **Intelligent**: Erkennt Kontext und Änderungstyp automatisch
- ✅ **Sauber**: Keine "von Claude erstellt" Hinweise
- ✅ **Flexibel**: Override mit eigener Message möglich


## WICHTIG 
Unterlasse Verweise auf die automatische Generierung durch die KI. Ich möchte in der Commit-Message nicht Verweise wie:
"Generated with [Claude Code](https://claude.ai/code)" haben


## Message-Format

```
<type>(<scope>): <description>

Beispiele:
feat(components): add drag drop functionality
fix(pagination): resolve URL object conversion
refactor(timesessions): streamline group assignment
style(dashboard): update card layout
docs(readme): add deployment instructions
```

Der Command folgt dem Conventional Commits Standard für maximale Kompatibilität mit Tools wie Semantic Release, Changelog-Generatoren etc.