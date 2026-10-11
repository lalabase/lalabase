import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

// Filters timeline items (comments, changes/activities, time sessions) and
// the sub-tasks section above the timeline.
//
// Since the header-line redesign (design mock "Der Verlauf liest sich, die
// Schalter verstecken sich", 04.09.2026) the switches live in a dropdown next
// to the "Verlauf" heading instead of a permanent chip row, and ONE word on
// the trigger (stateWord target) names what is shown: "alles" when every sort
// is on, "nur <Sorte>" when exactly one is (default: only comments), "gefiltert"
// otherwise - so a filtered view says so even with the menu closed. Row state
// travels as aria-pressed; the check mark is toggled by syncRow (see there
// for why not a Tailwind variant). The rows live INSIDE the lazy timeline frame and therefore
// connect AFTER this controller does - the *ToggleButtonTargetConnected
// callbacks sync their state once they arrive. The sub-tasks toggle is a
// section switch, not a timeline sort, and stays out of the state word.
export default class extends Controller {
  static targets = [
    "post", "activity", "timeSession", "subtasks", "dayGroup", "stateWord",
    "postsToggleButton", "toggleButton", "timeToggleButton", "subtasksToggleButton"
  ]
  static values = {
    showPosts: { type: Boolean, default: true },
    showActivities: { type: Boolean, default: false },
    showTimeSessions: { type: Boolean, default: false },
    showSubtasks: { type: Boolean, default: false }
  }

  connect() {
    // Initialize from session storage
    this.loadPreference()
    this.updateVisibility()
  }

  togglePosts() {
    this.showPostsValue = !this.showPostsValue
    this.updateVisibility()
    this.savePreference()
  }

  toggle() {
    this.showActivitiesValue = !this.showActivitiesValue
    this.updateVisibility()
    this.savePreference()
  }

  toggleTime() {
    this.showTimeSessionsValue = !this.showTimeSessionsValue
    this.updateVisibility()
    this.savePreference()
  }

  toggleSubtasks() {
    this.showSubtasksValue = !this.showSubtasksValue
    this.updateVisibility()
    this.savePreference()
  }

  updateVisibility() {
    this.postTargets.forEach(post => {
      post.style.display = this.showPostsValue ? 'block' : 'none'
    })

    this.activityTargets.forEach(activity => {
      activity.style.display = this.showActivitiesValue ? 'block' : 'none'
    })

    this.timeSessionTargets.forEach(timeSession => {
      timeSession.style.display = this.showTimeSessionsValue ? 'block' : 'none'
    })

    this.subtasksTargets.forEach(section => {
      section.style.display = this.showSubtasksValue ? 'block' : 'none'
    })

    if (this.hasPostsToggleButtonTarget) {
      this.syncRow(
        this.postsToggleButtonTarget,
        this.showPostsValue,
        I18n.t('stimulus.timeline_filter.hide_comments'),
        I18n.t('stimulus.timeline_filter.show_comments')
      )
    }
    if (this.hasToggleButtonTarget) {
      this.syncRow(
        this.toggleButtonTarget,
        this.showActivitiesValue,
        I18n.t('stimulus.timeline_filter.hide_activities'),
        I18n.t('stimulus.timeline_filter.show_activities')
      )
    }
    if (this.hasTimeToggleButtonTarget) {
      this.syncRow(
        this.timeToggleButtonTarget,
        this.showTimeSessionsValue,
        I18n.t('stimulus.timeline_filter.hide_time_tracking'),
        I18n.t('stimulus.timeline_filter.show_time_tracking')
      )
    }
    if (this.hasSubtasksToggleButtonTarget) {
      this.syncRow(
        this.subtasksToggleButtonTarget,
        this.showSubtasksValue,
        I18n.t('stimulus.timeline_filter.hide_subtasks'),
        I18n.t('stimulus.timeline_filter.show_subtasks')
      )
    }

    this.updateStateWord()
    this.syncDayGroups()
  }

  // ONE word on the closed trigger names what the timeline shows. Only the
  // sorts whose row actually exists count - a user without time-session read
  // has no time row, and "alles" must not lie about a sort they cannot see.
  updateStateWord() {
    if (!this.hasStateWordTarget) return

    const sorts = [
      { on: this.showPostsValue, key: 'state_only_comments' },
      { on: this.showActivitiesValue, key: 'state_only_changes' }
    ]
    if (this.hasTimeToggleButtonTarget) {
      sorts.push({ on: this.showTimeSessionsValue, key: 'state_only_time_entries' })
    }

    const active = sorts.filter(sort => sort.on)
    let key
    if (active.length === sorts.length) {
      key = 'state_all'
    } else if (active.length === 1) {
      key = active[0].key
    } else {
      key = 'state_filtered'
    }

    this.stateWordTarget.textContent = I18n.t(`stimulus.timeline_filter.${key}`)
  }

  // T4: a day group whose items are ALL hidden hides its date header too,
  // otherwise toggling leaves a page of orphaned dates.
  syncDayGroups() {
    this.dayGroupTargets.forEach(group => {
      const items = group.querySelectorAll(
        '[data-timeline-filter-target~="post"], [data-timeline-filter-target~="activity"], [data-timeline-filter-target~="timeSession"]'
      )
      const anyVisible = Array.from(items).some(el => el.style.display !== 'none')
      group.style.display = anyVisible ? 'block' : 'none'
    })
  }

  syncRow(button, on, hideTitle, showTitle) {
    button.setAttribute("aria-pressed", on ? "true" : "false")
    button.title = on ? hideTitle : showTitle
    // The check mark is toggled HERE, not via a group-aria-pressed Tailwind
    // variant: that variant never made it into the compiled CSS, so no check
    // was visible at all (found live 04.09.).
    const check = button.querySelector('.bi-check-lg')
    if (check) check.classList.toggle('invisible', !on)
  }

  savePreference() {
    const ticketId = this.element.dataset.ticketId
    if (ticketId) {
      sessionStorage.setItem(`ticket-show-posts-${ticketId}`, this.showPostsValue)
      sessionStorage.setItem(`ticket-show-activities-${ticketId}`, this.showActivitiesValue)
      sessionStorage.setItem(`ticket-show-time-sessions-${ticketId}`, this.showTimeSessionsValue)
      sessionStorage.setItem(`ticket-show-subtasks-${ticketId}`, this.showSubtasksValue)
    }
  }

  loadPreference() {
    const ticketId = this.element.dataset.ticketId
    if (ticketId) {
      const storedPosts = sessionStorage.getItem(`ticket-show-posts-${ticketId}`)
      if (storedPosts !== null) {
        this.showPostsValue = storedPosts === 'true'
      }

      const storedActivities = sessionStorage.getItem(`ticket-show-activities-${ticketId}`)
      if (storedActivities !== null) {
        this.showActivitiesValue = storedActivities === 'true'
      }

      const storedTimeSessions = sessionStorage.getItem(`ticket-show-time-sessions-${ticketId}`)
      if (storedTimeSessions !== null) {
        this.showTimeSessionsValue = storedTimeSessions === 'true'
      }

      const storedSubtasks = sessionStorage.getItem(`ticket-show-subtasks-${ticketId}`)
      if (storedSubtasks !== null) {
        this.showSubtasksValue = storedSubtasks === 'true'
      }
    }
  }

  showPostsValueChanged() {
    this.updateVisibility()
  }

  showActivitiesValueChanged() {
    this.updateVisibility()
  }

  showTimeSessionsValueChanged() {
    this.updateVisibility()
  }

  showSubtasksValueChanged() {
    this.updateVisibility()
  }

  postTargetConnected(element) {
    element.style.display = this.showPostsValue ? 'block' : 'none'
  }

  activityTargetConnected(element) {
    element.style.display = this.showActivitiesValue ? 'block' : 'none'
  }

  timeSessionTargetConnected(element) {
    element.style.display = this.showTimeSessionsValue ? 'block' : 'none'
  }

  subtasksTargetConnected(element) {
    element.style.display = this.showSubtasksValue ? 'block' : 'none'
  }

  postsToggleButtonTargetConnected() {
    this.updateVisibility()
  }

  toggleButtonTargetConnected() {
    this.updateVisibility()
  }

  timeToggleButtonTargetConnected() {
    this.updateVisibility()
  }

  subtasksToggleButtonTargetConnected() {
    this.updateVisibility()
  }

  stateWordTargetConnected() {
    this.updateVisibility()
  }

  dayGroupTargetConnected() {
    this.updateVisibility()
  }
}
