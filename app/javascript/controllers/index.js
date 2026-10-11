// CUSTOM VERSION - DO NOT OVERRIDE WITH rails stimulus:manifest:update
// Use rails stimulus:manifest:update_safe instead
// See docs/STIMULUS_CONTROLLER_MANAGEMENT.md for details

// Configure Stimulus development experience
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"

// Eager load all controllers defined in the importmap
// This uses the importmap to resolve controller paths with proper hashing
eagerLoadControllersFrom("controllers", application)
