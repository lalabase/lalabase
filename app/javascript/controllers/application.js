import { Application } from "@hotwired/stimulus"

// Keep the default Stimulus initialization
// so as not to cause any compatibility problems
const application = Application.start();

// Configure Stimulus development experience
application.debug = false;
window.Stimulus = application;

export { application }
