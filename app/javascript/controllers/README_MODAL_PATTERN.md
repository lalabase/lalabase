# Modal Pattern Dokumentation

## Überblick

Diese Dokumentation beschreibt das Modal-Pattern der Anwendung: ein Modal ist der **Inhalt eines Turbo-Frames**. Ein Link lädt das Formular in den Frame, das Verbinden des Controllers ist das Öffnen, das Leeren des Frames ist das Schließen.

Referenz-Implementierung ist `ticket_relation_modal_controller.js` (das Modal „Verknüpfen“ eines Tickets, Markup in `organisations/tickets/relations/_modal.html.erb`): Fokusfalle über `dialog_a11y`, Schließen über Hintergrund und Escape, Rückgabe des Fokus an den Auslöser. Bis zum 17.10.2026 war es `meeting_modal_controller.js`; er wurde gelöscht, weil „Neues Meeting“ auf „Alle Meetings“ seitdem in der Bahn öffnet. Bis zum 16.09.2026 war es `time_session_modal_controller.js`; er wurde zusammen mit dem Zeit-Knopf im Meetings-Kopf gelöscht, seiner letzten Einbindung. Beide blendeten ein Modal ein und aus, das fest in der Seite stand; diese Form gibt es nicht mehr.

## Design-Philosophie

1. **Das Modal steht nur in der Seite, solange es offen ist**: kein verstecktes Markup, kein Zustand „offen/zu“ im Controller
2. **Kein gemeinsamer Scope mit dem Auslöser**: Auslöser sind Links mit `data-turbo-frame`, sie dürfen irgendwo auf der Seite stehen (auch in einem Menü)
3. **Jede Öffnung trägt eine eigene ID (Token)**: Ablehnung und Speichern treffen nur sie, eine späte Antwort an ein geschlossenes Modal findet nichts
4. **Server entscheidet**: Fehler und Erfolg kommen als Turbo Streams, der Controller zählt keine Erfolge

## Implementierung eines neuen Modals

### Schritt 1: Leerer Frame und Auslöser

```erb
<%# In der Seite, neben dem Abschnitt, zu dem das Modal gehört %>
<%= turbo_frame_tag beispiel_modal_id(record) %>

<%# Ein Auslöser, beliebig viele, überall auf der Seite %>
<%= link_to t('...'), new_beispiel_path(record),
            id: beispiel_trigger_id(record),
            data: { turbo_frame: beispiel_modal_id(record) } %>
```

Die `new`-Action rendert den Frame (`layout: false`) mit dem Modal-Partial darin und erzeugt das Token der Öffnung.

### Schritt 2: Modal-Partial

```erb
<div id="<%= beispiel_modal_instance_id(record, token) %>"
     data-controller="beispiel-modal"
     data-beispiel-modal-return-id-value="<%= beispiel_trigger_id(record) %>"
     data-action="keydown@window->beispiel-modal#closeOnEscape keydown@window->beispiel-modal#trapFocus">
  <div class="fixed inset-0 z-50 overflow-y-auto" data-action="click->beispiel-modal#closeOnBackdrop">
    <div class="fixed inset-0 bg-gray-500 bg-opacity-60" aria-hidden="true"></div>
    <div class="relative flex min-h-screen items-center justify-center p-4"
         data-action="click->beispiel-modal#closeOnBackdrop">
      <div role="dialog" aria-modal="true" aria-labelledby="beispiel-title"
           data-beispiel-modal-target="card" class="...">
        <h3 id="beispiel-title"><%= t('...') %></h3>
        <button type="button" aria-label="<%= t('...') %>" data-action="click->beispiel-modal#close">
          <i class="bi bi-x-lg" aria-hidden="true"></i>
        </button>
        <%= form_with ..., format: :turbo_stream do |form| %>
          <%= hidden_field_tag :modal_token, token %>
          <%# Felder %>
        <% end %>
      </div>
    </div>
  </div>
</div>
```

### Schritt 3: Controller

Kopieren Sie `ticket_relation_modal_controller.js` und passen Sie den Namen an. Was bleibt:

* `connect()`: verwirft sich selbst, wenn der Frame nicht sichtbar ist (eine geschlossene Bahn), merkt sich am **Frame** die ID des Auslösers, sperrt das Scrollen der Seite, setzt den Fokus ins Modal.
* `disconnect()`: gibt das Scrollen frei, entfernt `src` vom Frame (der nächste Auslöser lädt neu) und gibt den Fokus an den Auslöser zurück, sobald kein Modal mehr im Frame steht.
* `close()`: entfernt `src` und leert den Frame.
* `closeOnBackdrop(event)`: nur ein Klick auf den Hintergrund selbst.
* `closeOnEscape(event)`: schließt nicht, wenn ein Kind das Escape schon benutzt hat (`event.defaultPrevented`).
* `trapFocus(event)`: `trapTabKey` aus `lib/dialog_a11y.js`.
* `ownsEscape()`: Pflicht für jedes Escape (`lib/escape_owner.js`). Das Modal steht nur in der Seite, solange es offen ist, also antwortet es `true`. Sonst schließt Escape auch die Detail-Bahn dahinter.

Was wegfällt: alles Fachliche der Vorlage (Arten, Verzögerung, `kindChanged`).

### Schritt 4: Turbo-Stream-Antworten

```erb
<%# Abgelehnt: genau diese Öffnung ersetzen, mit dem Gesendeten und der Meldung %>
<%= turbo_stream.replace beispiel_modal_instance_id(@record, @modal_token) do %>
  <%= render 'beispiel/modal', record: @record, token: @modal_token, errors: @errors %>
<% end %>

<%# Gespeichert: Abschnitt neu zeichnen, genau diese Öffnung entfernen (der Controller
    räumt beim disconnect auf), Flash zeigen %>
<%= turbo_stream.replace beispiel_section_id(@record), partial: '...' %>
<%= turbo_stream.remove beispiel_modal_instance_id(@record, @modal_token) %>
<%= turbo_stream.prepend 'flash', partial: 'layouts/flash', locals: { flash: @flash_message } %>
```

## Best Practices

### 1. IDs aus Helfern
Frame, Öffnung und Auslöser bekommen ihre IDs aus je einem Helfer (Vorbild: `TicketRelationsHelper`), damit Partial, Stream und Controller dieselbe Zeichenkette benutzen.

### 2. Stimulus Controller Naming
Folgen Sie der Konvention: `[resource]-modal`, zum Beispiel `ticket-relation-modal`.

### 3. Z-Index Management
- Modal und Hintergrund: `z-50` bzw. `z-modal`
- Verschachtelte Modals vermeiden!

## Häufige Probleme

1. **Das Modal öffnet nicht**: Der Link nennt einen Frame, den die Seite nicht hat, oder die Antwort der `new`-Action trägt den Frame nicht.
2. **Eine späte Antwort öffnet ein geschlossenes Modal wieder**: Die Streams treffen den Frame statt der Öffnung. Sie zielen immer auf die ID mit Token.
3. **Escape schließt auch die Detail-Bahn dahinter**: `ownsEscape()` fehlt oder antwortet falsch (`spec/architecture/escape_owner_guard_spec.rb` meldet das Fehlen).
4. **Der Fokus landet nach dem Schließen auf `<body>`**: Der Auslöser hat keine ID, oder ein Stream hat ihn ersetzt, ohne sie zu behalten.

## Tests

Empfohlene Szenarien (Vorbild: `spec/system/ticket_relations_spec.rb`):
- Öffnen über jeden Auslöser, Schließen über ✕, Hintergrund und Escape
- Escape schließt nur das Modal, nicht die Bahn dahinter
- Speichern (Erfolg) und Ablehnung (das Modal bleibt mit dem Gesendeten und der Meldung)
- Tab bleibt im Modal, der Fokus kehrt zum Auslöser zurück
