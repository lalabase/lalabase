import { Controller } from "@hotwired/stimulus"

// Expanding/collapsing the projects in the sidebar.
//
// - Each project expands/collapses INDEPENDENTLY (not an accordion that collapses others);
//   any number can be open at the same time.
// - The open state is kept as a set of project IDs in localStorage and
//   restored on load.
// - IMPORTANT (please read before making changes): The server renders ALL projects
//   collapsed (aria-expanded=false). The expanded state comes EXCLUSIVELY
//   from localStorage and does NOT depend on which project is currently open.
//   This is intentional: that way a project does not expand automatically
//   ("explode") when you navigate into it via a pinned item —
//   the state stays stable and predictable.
// - The toggle trigger is the whole project header (chevron AND name). You reach the dashboard
//   via the dashboard menu item, not via the header.
const STORAGE_KEY = "sidebar_open_projects"

export default class extends Controller {
  static targets = ["item"]

  connect() {
    this.openProjects = this.loadOpenProjects()
    // Restore projects the user previously expanded.
    this.itemTargets.forEach((item) => {
      // Hidden ("weniger Projekte") projects deliberately do NOT remember their
      // expanded state — they always start collapsed when the group is revealed.
      if (this.isHiddenProject(item)) return
      if (this.openProjects.has(item.dataset.projectId)) {
        this.setExpanded(item, true)
      }
    })
  }

  // Chevron click: expand/collapse.
  toggleProject(event) {
    event.preventDefault()
    event.stopPropagation()

    const item = this.itemFor(event)
    if (!item) return

    this.setExpanded(item, !this.isExpanded(item))
    this.persistState(item)
  }

  isExpanded(item) {
    const header = item.querySelector("[aria-expanded]")
    return header ? header.getAttribute("aria-expanded") === "true" : true
  }

  setExpanded(item, expanded) {
    // Only toggle the "extra" items of THIS project (exclude nested items).
    item.querySelectorAll("[data-extra]").forEach((li) => {
      if (li.closest("[data-sidebar-project-accordion-target='item']") === item) {
        li.classList.toggle("hidden", !expanded)
      }
    })

    const chevron = item.querySelector("[data-chevron]")
    if (chevron) chevron.classList.toggle("rotate-90", expanded)

    const header = item.querySelector("[aria-expanded]")
    if (header) header.setAttribute("aria-expanded", String(expanded))
  }

  // Persist this project's expanded state in localStorage.
  persistState(item) {
    // Do not remember the expanded state of hidden ("weniger Projekte") projects:
    // they must reappear collapsed every time the group is revealed.
    if (this.isHiddenProject(item)) return

    const id = item.dataset.projectId
    if (this.isExpanded(item)) {
      this.openProjects.add(id)
    } else {
      this.openProjects.delete(id)
    }
    this.persist()
  }

  // A project inside the "more projects" reveal container. Its expanded state is
  // ephemeral (see connect/persistState/toggleHiddenProjects).
  isHiddenProject(item) {
    return Boolean(item.closest("[data-hidden-projects]"))
  }

  itemFor(event) {
    return event.currentTarget.closest("[data-sidebar-project-accordion-target='item']")
  }

  // "more projects" — shows/hides the inactive projects (along with label + chevron).
  toggleHiddenProjects(event) {
    event.preventDefault()
    event.stopPropagation()

    const container = this.element.querySelector("[data-hidden-projects]")
    const label = event.currentTarget.querySelector("[data-hidden-projects-label]")
    const chevron = event.currentTarget.querySelector("[data-hidden-projects-chevron]")
    if (!container) return

    const isHidden = container.classList.contains("hidden")
    container.classList.toggle("hidden", !isHidden)

    // Collapsing the group ("weniger Projekte") also collapses every project
    // inside it, so the next reveal always starts from a clean, collapsed state.
    if (!isHidden) {
      container
        .querySelectorAll("[data-sidebar-project-accordion-target='item']")
        .forEach((item) => this.setExpanded(item, false))
    }

    if (chevron) chevron.classList.toggle("rotate-180", isHidden)
    if (label) {
      label.textContent = isHidden ? label.dataset.lessText : label.dataset.moreText
    }
  }

  loadOpenProjects() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY)
      return new Set(raw ? JSON.parse(raw) : [])
    } catch (e) {
      return new Set()
    }
  }

  persist() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify([...this.openProjects]))
    } catch (e) {
      // localStorage not available -> silently ignore
    }
  }
}
