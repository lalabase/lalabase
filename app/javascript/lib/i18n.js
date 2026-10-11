// JavaScript I18n implementation for Stimulus controllers
// Provides access to Rails translations in JavaScript

class I18n {
  static get locale() {
    return window.locale || 'de';
  }

  static t(key, options = {}) {
    if (!window.translations) {
      console.warn('I18n: window.translations not available, falling back to key');
      return key;
    }

    // Navigate through nested object using dot notation
    const keys = key.split('.');
    let value = window.translations;

    for (const k of keys) {
      if (value && typeof value === 'object' && k in value) {
        value = value[k];
      } else {
        // Key not found, return key or default
        return options.default || key;
      }
    }

    // Pluralisation. The shim had none, so every counted string in a Stimulus
    // controller had to write its own plural: the assignment panel said
    // "2 Zeit-Session(s) ausgewählt", and a key with one/other would have
    // resolved to the object and printed [object Object].
    //
    // one/other only, deliberately: those are the forms Rails' :de and :en
    // pluralisation rules actually use. Inventing a "zero" branch here would
    // make the same key read differently in JavaScript than on the server.
    if (value && typeof value === 'object' && typeof options.count === 'number') {
      // A half-defined key (only one of the two forms) still answers with the
      // other form rather than leaking the raw key into the page.
      value = options.count === 1 ? (value.one ?? value.other) : (value.other ?? value.one);
    }

    // Handle interpolation
    if (typeof value === 'string' && options) {
      return this.interpolate(value, options);
    }

    return value || options.default || key;
  }

  static interpolate(text, options = {}) {
    // Replace placeholders like %{name} with values from options
    return text.replace(/%\{(\w+)\}/g, (match, key) => {
      return options.hasOwnProperty(key) ? options[key] : match;
    });
  }

  // Helper method for confirm dialogs
  static confirm(key, options = {}) {
    const message = this.t(key, options);
    return confirm(message);
  }

  // Helper method for alert dialogs
  static alert(key, options = {}) {
    const message = this.t(key, options);
    alert(message);
  }

  // Helper method to get text for dynamic content
  static text(key, options = {}) {
    return this.t(key, options);
  }
}

export default I18n;