import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "actionSelect",
    "roleSelection", 
    "mappingInfo",
    "emptyState",
    "userRow",
    "progressBar",
    "progressPercent",
    "progressText",
    "createCount",
    "mapCount",
    "skipCount",
    "importButton"
  ]
  
  connect() {
    this.updateCounters()
  }
  
  actionChanged(event) {
    const select = event.target
    this.updateCounters()
    this.toggleUserOptions(select)
  }
  
  updateCounters() {
    let createCount = 0
    let mapCount = 0
    let skipCount = 0
    let totalSelected = 0
    
    this.actionSelectTargets.forEach(select => {
      const value = select.value
      if (value && value !== '') {
        totalSelected++
        if (value === 'create') {
          createCount++
        } else if (value.startsWith('map:')) {
          mapCount++
        } else if (value === 'skip') {
          skipCount++
        }
      }
    })
    
    // Update counter displays
    this.updateCounterBox(this.createCountTarget, createCount, 'create')
    this.updateCounterBox(this.mapCountTarget, mapCount, 'map')
    this.updateCounterBox(this.skipCountTarget, skipCount, 'skip')
    
    // Update progress bar
    this.updateProgressBar(totalSelected, this.actionSelectTargets.length)
    
    // Enable/disable import button
    const allSelected = totalSelected === this.actionSelectTargets.length
    
    if (allSelected) {
      this.importButtonTarget.disabled = false
      this.importButtonTarget.className = "py-2.5 px-5 relative inline-flex flex-row items-center justify-center gap-x-2 rounded text-sm tracking-[.00714em] font-medium border border-stroke bg-lime-200 hover:bg-lime-300 focus:bg-lime-300 text-cream-900 hover:shadow-sm focus:shadow-sm cursor-pointer"
    } else {
      this.importButtonTarget.disabled = true
      this.importButtonTarget.className = "py-2.5 px-5 relative inline-flex flex-row items-center justify-center gap-x-2 rounded text-sm tracking-[.00714em] font-medium border border-stroke bg-gray-200 text-cream-900/50 cursor-not-allowed"
    }
  }
  
  updateProgressBar(completed, total) {
    const percentage = total > 0 ? Math.round((completed / total) * 100) : 0
    
    this.progressBarTarget.style.width = `${percentage}%`
    this.progressPercentTarget.textContent = `${percentage}%`
    this.progressTextTarget.textContent = `${completed} von ${total} User konfiguriert`
    
    // Hide percentage text if progress bar is too narrow
    if (percentage < 15) {
      this.progressPercentTarget.style.opacity = '0'
    } else {
      this.progressPercentTarget.style.opacity = '1'
    }
  }
  
  updateCounterBox(box, count, type) {
    const numberEl = box.querySelector('.text-2xl')
    numberEl.textContent = count
    
    if (count === 0) {
      box.className = box.className.replace(/bg-\w+-200/, 'bg-gray-100')
      box.querySelector('.text-2xl').className = 'text-2xl font-semibold text-black/50'
      box.querySelector('.text-sm').className = 'text-sm font-medium text-black/50'
    } else {
      // Restore original colors based on box type
      if (type === 'create') {
        box.className = box.className.replace(/bg-gray-100/, 'bg-lime-200')
      } else if (type === 'map') {
        box.className = box.className.replace(/bg-gray-100/, 'bg-cobalt-200')
      } else if (type === 'skip') {
        box.className = box.className.replace(/bg-gray-100/, 'bg-red-200')
      }
      box.querySelector('.text-2xl').className = 'text-2xl font-semibold text-black'
      box.querySelector('.text-sm').className = 'text-sm font-medium text-black'
    }
  }
  
  toggleUserOptions(select) {
    const userId = select.dataset.userId
    const roleSelection = this.element.querySelector(`.role-selection[data-user-id="${userId}"]`)
    const mappingInfo = this.element.querySelector(`.mapping-info[data-user-id="${userId}"]`)
    const emptyState = this.element.querySelector(`.empty-state[data-user-id="${userId}"]`)
    const userRow = this.element.querySelector(`.user-row[data-user-id="${userId}"]`)
    
    // Update row styling based on action
    this.updateRowStyling(userRow, select.value)
    
    if (select.value === '' || !select.value) {
      // No action selected
      if (roleSelection) roleSelection.style.display = 'none'
      if (mappingInfo) mappingInfo.style.display = 'none'
      if (emptyState) emptyState.style.display = 'block'
    } else if (select.value === 'create') {
      // Show role selection for create action
      if (roleSelection) roleSelection.style.display = 'block'
      if (mappingInfo) mappingInfo.style.display = 'none'
      if (emptyState) emptyState.style.display = 'none'
    } else if (select.value.startsWith('map:')) {
      if (roleSelection) roleSelection.style.display = 'none'
      if (mappingInfo) {
        mappingInfo.style.display = 'block'
        
        // Update mapping info for selected user
        const selectedUserId = select.value.split(':')[1]
        const option = select.querySelector(`option[value="map:${selectedUserId}"]`)
        if (option) {
          const isExact = option.textContent.includes('(Exakt)')
          const email = option.textContent.replace('Zuordnen zu: ', '').replace(' (Exakt)', '')
          const bgColor = isExact ? 'bg-lime-200' : 'bg-gray-200'
          const label = isExact ? '✓' : '→'
          
          mappingInfo.innerHTML = `
            <div class="text-sm font-medium text-black ${bgColor} border border-black rounded px-2 py-1 inline-block">${label} ${email}</div>
            <div class="text-xs text-black mt-1">Wird zugeordnet</div>
          `
        }
      }
      if (emptyState) emptyState.style.display = 'none'
    } else if (select.value === 'skip') {
      if (roleSelection) roleSelection.style.display = 'none'
      if (mappingInfo) mappingInfo.style.display = 'none'
      if (emptyState) emptyState.style.display = 'none'
    }
  }
  
  updateRowStyling(row, action) {
    if (!row) return
    
    // Remove all action-specific classes
    row.classList.remove('bg-red-100', 'bg-lime-50', 'bg-cobalt-50', 'hover:bg-red-200', 'hover:bg-lime-100', 'hover:bg-cobalt-100', 'hover:bg-gray-100')
    
    // Get all text elements in the row
    const textElements = row.querySelectorAll('div, span, td')
    
    if (action === 'skip') {
      // Red tint for skipped users
      row.classList.add('bg-red-100', 'hover:bg-red-200')
      // Gray out text for skipped users
      textElements.forEach(el => {
        if (el.style.color !== 'rgba(0, 0, 0, 0.6)') {
          el.style.color = 'rgba(0, 0, 0, 0.6)'
        }
      })
    } else {
      // Restore normal text color for non-skipped users
      textElements.forEach(el => {
        el.style.color = ''
      })
      
      if (action === 'create') {
        // Green tint for new users
        row.classList.add('bg-lime-50', 'hover:bg-lime-100')
      } else if (action.startsWith('map:')) {
        // Blue tint for mapped users
        row.classList.add('bg-cobalt-50', 'hover:bg-cobalt-100')
      } else {
        // Default neutral hover for unselected
        row.classList.add('hover:bg-gray-100')
      }
    }
  }
}