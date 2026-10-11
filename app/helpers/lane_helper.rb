# frozen_string_literal: true

# The page's lane parameters, ONE definition in three groups (D9 of
# doc/dateivorschau_plan.md), rendered once on the page wrapper as
# data-lane-params and read by lib/lane/params.js:
#   selection  the parameters that name the open object (note_id, document_id;
#              ticket_id on the ticket page)
#   preview    the sub-state of the open object (a version in the lane)
#   form       a form as a state of the page (new)
#   ignore     page-mode parameters that are neither list nor lane state and
#              come and go on their own (viewport, which the viewport
#              controller writes after the page has rendered); the restorer's
#              list part leaves them out
# Each reader derives its own rule from the groups: a preview is not a
# selection, so one list for every purpose would be wrong twice over.
module LaneHelper
  PAGE_MODE_PARAMS = %w[viewport].freeze

  # The words lib/lane/history.js (previewAddress) replaces with the ids of a
  # popped preview state; a page with previews writes its preview route once
  # with them, as data-lane-preview-url on the wrapper. Same two words on both
  # sides, on purpose: the restorer knows no route shape.
  SELECTION_PLACEHOLDER = '__SELECTION__'
  PREVIEW_PLACEHOLDER = '__PREVIEW__'

  def lane_params_json(selection:, preview: [], form: [], ignore: PAGE_MODE_PARAMS)
    { selection: Array(selection), preview: Array(preview), form: Array(form), ignore: Array(ignore) }.to_json
  end
end
