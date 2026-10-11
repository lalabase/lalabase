# Modal Pattern Dokumentation

## Überblick

Diese Dokumentation beschreibt das Modal-Pattern, das für TimeSession entwickelt wurde und als Vorlage für andere Modals in der Anwendung dienen soll.

Referenz-Implementierung ist `meeting_modal_controller.js` („Neues Meeting“ in der Meetings-Übersicht der Organisation). Bis zum 16.09.2026 war es `time_session_modal_controller.js`; er wurde zusammen mit dem Zeit-Knopf im Meetings-Kopf gelöscht, seiner letzten Einbindung.

## Design-Philosophie

1. **Einfachheit über Komplexität**: Jeder Controller hat eine klare, einzelne Verantwortung
2. **Keine versteckten Abhängigkeiten**: Alles ist explizit und nachvollziehbar
3. **Event-basierte Kommunikation**: Nutzt Turbo Events für saubere Integration
4. **Wiederverwendbarkeit**: Code ist als Template für andere Modals gedacht

## Implementierung eines neuen Modals

### Schritt 1: Controller erstellen

Kopieren Sie `meeting_modal_controller.js` und passen Sie an:

```javascript
// beispiel_modal_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "form"]
  
  // Ändern Sie die Form-ID in handleTurboSuccess
  handleTurboSuccess(event) {
    const form = event.target
    if (form && form.id === "beispiel_form" && event.detail.success) {
      this.close()
    }
  }
  
  // Rest bleibt gleich...
}
```

### Schritt 2: HTML-Struktur

```erb
<div data-controller="beispiel-modal" 
     data-action="keydown@window->beispiel-modal#closeOnEscape">
  
  <!-- Trigger Button -->
  <button data-action="click->beispiel-modal#open" class="...">
    Öffnen
  </button>
  
  <!-- Modal -->
  <div data-beispiel-modal-target="modal" 
       data-action="click->beispiel-modal#closeOnBackdrop"
       class="fixed z-modal inset-0 overflow-y-auto hidden">
    
    <!-- Backdrop -->
    <div class="fixed inset-0 bg-gray-500 bg-opacity-60"></div>
    
    <!-- Modal Content -->
    <div class="flex items-center justify-center min-h-screen p-4">
      <div class="bg-white rounded-lg p-6 max-w-md w-full relative">
        
        <!-- Header -->
        <div class="flex justify-between items-center mb-4">
          <h3>Modal Titel</h3>
          <button data-action="click->beispiel-modal#close">×</button>
        </div>
        
        <!-- Form Container -->
        <div data-beispiel-modal-target="form">
          <form id="beispiel_form">
            <!-- Formular-Inhalt -->
          </form>
        </div>
        
      </div>
    </div>
  </div>
</div>
```

### Schritt 3: Turbo Stream Response

```erb
<%# create.turbo_stream.erb %>
<% if @beispiel.errors.any? %>
  <%# Fehler anzeigen %>
  <%= turbo_stream.remove_all ".beispiel-error-container" %>
  <%= turbo_stream.prepend "beispiel_form" do %>
    <div class="rounded-lg bg-red-50 p-4 beispiel-error-container mb-4">
      <!-- Fehler-Inhalt -->
    </div>
  <% end %>
<% else %>
  <%# Erfolg %>
  <%= turbo_stream.update "flash", partial: "shared/flash" %>
  
  <%# Weitere Updates... %>
<% end %>
```

## Best Practices

### 1. Form IDs eindeutig halten
Jedes Modal sollte eine eindeutige Form-ID haben:
- `time_session_form`
- `ticket_form`
- `note_form`

### 2. Error Container Klassen
Verwenden Sie spezifische Klassen für Fehler-Container:
- `.time-session-error-container`
- `.ticket-error-container`
- `.note-error-container`

### 3. Stimulus Controller Naming
Folgen Sie der Konvention: `[resource]-modal`:
- `meeting-modal`
- `ticket-modal`
- `note-modal`

### 4. Z-Index Management
Verwenden Sie konsistente z-index Werte:
- Modal Backdrop: `z-modal`
- Modal Content: relativ positioniert
- Verschachtelte Modals vermeiden!

## Häufige Anpassungen

### Modal mit Turbo Frame

Wenn Ihr Modal Inhalte dynamisch lädt:

```erb
<turbo-frame id="modal_content_frame" src="<%= path %>">
  <!-- Ladeindikator -->
</turbo-frame>
```

### Modal mit mehreren Schritten

Nutzen Sie data-Attribute für Schritte:

```javascript
// In Ihrem Controller
static values = { currentStep: Number }

nextStep() {
  this.currentStepValue++
  this.showStep(this.currentStepValue)
}
```

### Integration mit anderen Controllern

Beispiel: Automatische Feldauswahl

```javascript
open() {
  super.open() // Basis-Funktionalität
  
  // Zusätzliche Logik
  const selector = this.element.querySelector('[data-controller="field-selector"]')
  if (selector) {
    // Trigger andere Controller
  }
}
```

## Debugging

### Console Logs
Die Controller haben bereits Debug-Ausgaben:
- "Modal Controller connected"
- "Form submitted successfully"
- Event-Details

### Häufige Probleme

1. **Modal schließt nicht**: 
   - Prüfen Sie die Form-ID in `handleTurboSuccess`
   - Stellen Sie sicher, dass `event.detail.success` true ist

2. **Form wird nicht zurückgesetzt**:
   - Prüfen Sie, ob form Target definiert ist
   - Stellen Sie sicher, dass das form Element gefunden wird

3. **ESC funktioniert nicht**:
   - Prüfen Sie data-action am Container
   - Stellen Sie sicher, dass keine anderen Handler interferieren

## Wartung

### Updates
Bei Änderungen am Base-Pattern:
1. Dokumentieren Sie die Änderung hier
2. Updaten Sie bestehende Modals schrittweise
3. Testen Sie die Rückwärtskompatibilität

### Tests
Empfohlene Test-Szenarien:
- Modal öffnen/schließen
- Form Submit (Erfolg und Fehler)
- Keyboard Navigation (ESC)
- Backdrop Click
- Form Reset nach Schließen

## Zusammenfassung

Dieses Modal-Pattern bietet eine solide Grundlage für konsistente, wartbare Modals in der gesamten Anwendung. Die Hauptvorteile sind:

- **Einfachheit**: Wenig Code, klare Struktur
- **Konsistenz**: Alle Modals verhalten sich gleich
- **Wartbarkeit**: Änderungen sind lokal begrenzt
- **Testbarkeit**: Klare Interfaces und Events

Bei Fragen oder Verbesserungsvorschlägen, bitte ein Issue erstellen oder die Dokumentation erweitern.