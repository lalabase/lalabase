// What: the one decision meeting_project_select_controller.js makes, as a pure
//   function so node:test can pin it: which form the frame below the project
//   select of "Alle Meetings" shows (meetings_overview/_new_meeting_lane).
// Why: the address comes from ERB, one per <option>, so no route is assembled
//   in the browser; and "nothing chosen" has to be one answer, because it
//   decides twice: when the choice changes, and when an answer arrives that was
//   asked for before the choice was taken back.

// The form address of the chosen project, or null when none is chosen (the
// prompt, an option without an address, no select at all).
export function chosenFormUrl(select) {
  const option = select && select.selectedOptions ? select.selectedOptions[0] : null
  const url = option && option.dataset ? option.dataset.formUrl : null
  return url || null
}
