// What: the one decision auto_submit_controller.js makes on every change and
//   input event, as a pure function so node:test can pin it.
// Why:  a form that submits itself has to know which controls count. An input
//   without a name contributes nothing to the submission, so a submit on its
//   account only sends what was already sent. That is not harmless either: the
//   billing picker's filter box (NeoAutosuggest) is such an input, and the
//   submit its keystrokes armed landed AFTER the whole-page visit a choice
//   makes and cancelled it (S4 review, the filter-line plan).
//
// Returns "debounced" for typing (text, search), null for a control that
// cannot change what the form sends (no name, or a submit/button control),
// and "now" for EVERY other named control -- select, checkbox, radio, date,
// hidden, and whatever else a form may grow. Deliberately a blacklist, the
// shape the controller always had: a new input type submits at once unless
// this list learns better.
export function submitTrigger(target) {
  if (!target || !target.name) return null
  if (target.type === "submit" || target.type === "button") return null
  // An explicit opt-out, for a control that only means something together with
  // another one. The custom period is two dates: submitting when the first
  // changes applies a range half of which the reader has not chosen yet ("from
  // June" against last month's "to"), and the list jumps to an answer nobody
  // asked. Those fields carry their own apply button instead.
  if (target.dataset && "autoSubmitSkip" in target.dataset) return null
  if (target.type === "text" || target.type === "search") return "debounced"

  return "now"
}
