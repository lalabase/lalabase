import I18n from "i18n"

/**
 * Shared module for time session modal and delete operations.
 * Used by time_session_popup_controller and time_session_actions_controller.
 * All functions are pure (no `this` context) — dependencies passed as parameters.
 */

// Parse organisation ID from current URL path (/org/:id/...)
function getOrganisationId() {
  const parts = window.location.pathname.split('/')
  const orgIndex = parts.indexOf('org')
  return (orgIndex !== -1 && parts.length > orgIndex + 1) ? parts[orgIndex + 1] : ''
}

// Build URL for a time session resource
function buildTimeSessionUrl(projectId, timeSessionId, action) {
  const organisationId = getOrganisationId()
  const isProjectContext = window.location.pathname.includes('/projects/')

  let base
  if (isProjectContext && projectId) {
    base = `/org/${organisationId}/projects/${projectId}/time_sessions/${timeSessionId}`
  } else {
    base = `/org/${organisationId}/time-tracking/${timeSessionId}`
  }

  return action ? `${base}/${action}` : base
}

// Create full-screen overlay backdrop
function createOverlay(timeSessionId, onClose) {
  const overlayId = `time-session-overlay-${timeSessionId}`
  let overlay = document.getElementById(overlayId)

  if (!overlay) {
    overlay = document.createElement('div')
    overlay.id = overlayId
    overlay.style.cssText = 'position:fixed;inset:0;z-index:999999;display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,0.5);backdrop-filter:blur(4px)'

    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) onClose()
    })

    document.body.appendChild(overlay)
  } else {
    overlay.style.display = 'flex'
  }

  return overlay
}

// Create modal box with header and loading spinner
function createModalContent(onClose) {
  const modalContent = document.createElement('div')
  modalContent.style.cssText = 'background:white;border-radius:0.5rem;padding:1.5rem;max-width:500px;width:100%;box-shadow:0 10px 25px rgba(0,0,0,0.5);border:2px solid black;position:relative'

  // Header
  const header = document.createElement('div')
  header.className = 'flex justify-between items-center mb-4 pb-3 border-b border-black'

  const title = document.createElement('h3')
  title.className = 'text-lg font-medium text-black'
  title.textContent = I18n.t('stimulus.time_session_actions.edit_title')

  const closeBtn = document.createElement('button')
  closeBtn.type = 'button'
  closeBtn.className = 'text-gray-400 hover:text-gray-500 focus:outline-none text-lg'
  closeBtn.innerHTML = '<i class="bi bi-x-lg"></i>'
  closeBtn.addEventListener('click', onClose)

  header.appendChild(title)
  header.appendChild(closeBtn)
  modalContent.appendChild(header)

  // Form container with loading spinner
  const formContainer = document.createElement('div')
  formContainer.innerHTML = `
    <div class="text-center py-8">
      <i class="bi bi-arrow-repeat text-2xl animate-spin inline-block"></i>
      <p class="mt-4 text-gray-500">${I18n.t('stimulus.time_session_actions.loading_form')}</p>
    </div>
  `
  modalContent.appendChild(formContainer)

  return { modalContent, formContainer }
}

// Load edit form via fetch, wire up cancel + submit handlers
function loadEditForm(url, formContainer, context, onClose) {
  fetch(url, {
    headers: {
      'Accept': 'text/html',
      'X-Requested-With': 'XMLHttpRequest'
    }
  })
  .then(response => {
    if (!response.ok) throw new Error('Network error')
    return response.text()
  })
  .then(html => {
    formContainer.innerHTML = html

    const form = formContainer.querySelector('form')
    if (!form) return

    // Wire up cancel buttons
    form.querySelectorAll('button[type="button"]').forEach(button => {
      if (button.textContent.trim() === I18n.t('stimulus.time_session_actions.cancel_button')) {
        const clone = button.cloneNode(true)
        button.parentNode.replaceChild(clone, button)
        clone.addEventListener('click', onClose)
      }
    })

    // Override form submit for direct POST (only once)
    if (form.getAttribute('data-direct-submit') !== 'true') {
      form.setAttribute('data-direct-submit', 'true')

      form.addEventListener('submit', (e) => {
        e.preventDefault()

        const submitBtn = form.querySelector('input[type="submit"], button[type="submit"]')
        if (submitBtn) {
          if (submitBtn.tagName === 'INPUT') {
            submitBtn.value = I18n.t('stimulus.time_session_actions.saving')
          } else {
            submitBtn.textContent = I18n.t('stimulus.time_session_actions.saving')
          }
          submitBtn.disabled = true
        }

        // Ensure redirect_after_update field
        if (!form.querySelector('[name="redirect_after_update"]')) {
          const input = document.createElement('input')
          input.type = 'hidden'
          input.name = 'redirect_after_update'
          input.value = 'true'
          form.appendChild(input)
        }

        // Ensure context field with correct value
        let contextField = form.querySelector('[name="context"]')
        if (!contextField) {
          contextField = document.createElement('input')
          contextField.type = 'hidden'
          contextField.name = 'context'
          form.appendChild(contextField)
        }

        const urlParams = new URL(form.action, window.location.origin).searchParams
        const urlContext = urlParams.get('context')
        const overlayContext = formContainer.closest('[id^="time-session-overlay-"]')?.dataset?.context
        const defaultContext = window.location.pathname.includes('/time_sessions') ? 'index_page' : 'ticket'
        contextField.value = urlContext || overlayContext || context || defaultContext

        form.setAttribute('data-turbo', 'false')
        form.submit()
      })
    }
  })
  .catch(error => {
    console.error('Error loading form:', error)
    formContainer.innerHTML = `
      <div class="bg-red-50 p-4 rounded-md">
        <div class="flex">
          <div class="flex-shrink-0">
            <i class="bi bi-exclamation-triangle text-red-400"></i>
          </div>
          <div class="ml-3">
            <h3 class="text-sm font-medium text-red-800">
              ${I18n.t('stimulus.time_session_actions.form_load_error')}
            </h3>
            <div class="mt-2 text-sm text-red-700">
              <p>${I18n.t('stimulus.time_session_actions.try_again_later')}</p>
            </div>
          </div>
        </div>
      </div>
    `
  })
}

/**
 * Close and remove modal overlay, re-enable body scrolling.
 */
export function closeModal(timeSessionId) {
  const overlay = document.getElementById(`time-session-overlay-${timeSessionId}`)
  if (overlay) overlay.remove()
  document.body.style.overflow = ''
}

/**
 * Send DELETE request for a time session.
 * On success: removes the DOM element and reloads the page.
 * Returns a promise so callers can attach custom error handling.
 */
export function performDelete(projectId, timeSessionId) {
  const url = buildTimeSessionUrl(projectId, timeSessionId)

  return fetch(url, {
    method: 'DELETE',
    headers: {
      'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content,
      'Accept': 'text/vnd.turbo-stream.html',
      'X-Requested-With': 'XMLHttpRequest'
    }
  }).then(response => {
    if (!response.ok) throw new Error('delete_failed')

    const el = document.getElementById(`time_session_${timeSessionId}`)
    if (el) el.remove()

    setTimeout(() => window.location.reload(), 100)
  })
}

/**
 * Open an edit modal for a time session.
 * Orchestrates overlay, modal content, and form loading.
 * Returns { cleanup } — call cleanup() in disconnect() to remove the escape listener.
 */
export function openEditModal({ projectId, timeSessionId, ticketId, context = 'ticket' }) {
  let escapeListener = null

  const onClose = () => {
    closeModal(timeSessionId)
    if (escapeListener) {
      document.removeEventListener('keydown', escapeListener)
      escapeListener = null
    }
  }

  const overlay = createOverlay(timeSessionId, onClose)
  overlay.dataset.context = context

  const { modalContent, formContainer } = createModalContent(onClose)
  overlay.innerHTML = ''
  overlay.appendChild(modalContent)

  // Build edit URL with params
  const url = buildTimeSessionUrl(projectId, timeSessionId, 'edit')
  const params = new URLSearchParams()
  if (ticketId) params.append('ticket_id', ticketId)
  params.append('context', context)

  loadEditForm(`${url}?${params}`, formContainer, context, onClose)

  // Prevent body scrolling
  document.body.style.overflow = 'hidden'

  // Escape key handler
  escapeListener = (e) => {
    if (e.key === 'Escape') onClose()
  }
  document.addEventListener('keydown', escapeListener)

  return {
    cleanup: () => {
      if (escapeListener) {
        document.removeEventListener('keydown', escapeListener)
        escapeListener = null
      }
    }
  }
}
