// What: the three stages of the meeting beside the ticket, from the grid's width
//   (lib/lane/meeting_panel_stage.js, doc/ticket_meeting_panel_plan.md S2).
// Type: node:test unit spec over numbers.
// Why: the stages switch at two widths, and each width is the sum of minimums, a panel
//   that grows with the grid and two channels. An off-by-one there shows a lane below its
//   minimum or tabs where two columns fit. Every boundary is pinned at n-1, n and n+1.
import { test } from "node:test"
import assert from "node:assert/strict"
import { MIN_LIST_PX, MIN_LANE_PX, STAGES, panelWidth, meetingPanelStage } from "../../../../app/javascript/lib/lane/meeting_panel_stage.js"

// The stylesheet's numbers (layout.css: --panel-min, --panel-share, --panel-max, --panel-gap).
const PANEL = { panelMin: 320, panelShare: 0.34, panelMax: 480, gap: 24 }
const stageAt = gridWidth => meetingPanelStage({ gridWidth, ...PANEL })

test("the minimums are the ones the split has always used", () => {
  assert.equal(MIN_LIST_PX, 320)
  assert.equal(MIN_LANE_PX, 360)
  assert.deepEqual(STAGES, ["wide", "medium", "narrow"])
})

test("panelWidth takes its share of the grid, held between its bounds", () => {
  assert.equal(panelWidth({ gridWidth: 900, ...PANEL }), 320)   // 306 is below the minimum
  assert.equal(panelWidth({ gridWidth: 1000, ...PANEL }), 340)
  assert.equal(panelWidth({ gridWidth: 1500, ...PANEL }), 480)  // 510 is above the maximum
})

// Medium needs the lane's minimum beside the panel: 360 + 320 + 2 * 24 = 728.
test("narrow below 728 px, medium from 728 px", () => {
  assert.equal(stageAt(727), "narrow")
  assert.equal(stageAt(728), "medium")
  assert.equal(stageAt(729), "medium")
})

// Wide needs list and lane minimums beside a panel that has grown with the grid:
// g - 0.34 g - 48 >= 680, so g >= 1103.03.
test("medium below 1104 px, wide from 1104 px", () => {
  assert.equal(stageAt(1103), "medium")
  assert.equal(stageAt(1104), "wide")
  assert.equal(stageAt(1105), "wide")
})

test("a panel at its maximum leaves everything else to list and lane", () => {
  assert.equal(stageAt(2560), "wide")
})

test("the boundaries follow the minimums and the channel it is given", () => {
  const custom = { ...PANEL, gap: 0, listMin: 100, laneMin: 200 }
  // medium: rest = g - 320 >= 200 (the panel stays at its minimum up to 941 px)
  assert.equal(meetingPanelStage({ gridWidth: 519, ...custom }), "narrow")
  assert.equal(meetingPanelStage({ gridWidth: 520, ...custom }), "medium")
  // wide: rest = g - 320 >= 300
  assert.equal(meetingPanelStage({ gridWidth: 619, ...custom }), "medium")
  assert.equal(meetingPanelStage({ gridWidth: 620, ...custom }), "wide")
})
