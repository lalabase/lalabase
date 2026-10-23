// How much of the meeting beside the ticket fits (doc/ticket_meeting_panel_plan.md, S2).
// Decided by the GRID's width, not the window's: the assistant docks to the left of the
// page at 280 to 640 px and can be dragged, so one window can hold three columns or not.
//
//   wide    list, ticket and meeting side by side; the list keeps its share of the rest
//   medium  ticket and meeting; the list yields first (its track goes to 0 px)
//   narrow  ticket and meeting as two tabs in one column, never stacked
//
// The minimums of the list and the lane live HERE, once: lane_split_controller clamps its
// drag with them and writes them to the grid for the stylesheet. The panel's own width is
// the stylesheet's (--panel-min, --panel-share, --panel-max in layout.css); the caller
// reads those and passes them in, so the clamp the browser lays out and the clamp this
// function computes are the same three numbers.

// The list stays wide enough for a number, a title and one more column; the lane wide
// enough for the running text it exists for.
export const MIN_LIST_PX = 320
export const MIN_LANE_PX = 360

export const STAGES = Object.freeze(["wide", "medium", "narrow"])

// The width the panel takes in a grid this wide: its share, held between its bounds,
// as the stylesheet's clamp() lays it out.
export function panelWidth({ gridWidth, panelMin, panelShare, panelMax }) {
  return Math.min(Math.max(gridWidth * panelShare, panelMin), panelMax)
}

// gap is the channel between two tracks. Both stages with a panel have three tracks
// (in medium the list's is 0 px wide but still a track), so two channels.
export function meetingPanelStage({
  gridWidth, panelMin, panelShare, panelMax, gap, listMin = MIN_LIST_PX, laneMin = MIN_LANE_PX
}) {
  const rest = gridWidth - panelWidth({ gridWidth, panelMin, panelShare, panelMax }) - 2 * gap
  if (rest >= listMin + laneMin) return "wide"
  if (rest >= laneMin) return "medium"
  return "narrow"
}
