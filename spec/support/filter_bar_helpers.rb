# frozen_string_literal: true

# The filter bar in a browser spec.
module FilterBarHelpers
  # The name field of "Als Ansicht sichern", ready to be typed into.
  #
  # The bar fills the field with a suggested name and selects it one animation
  # frame after the row shows (filter_bar#openSaveModal), so that Enter alone
  # is an answer. A spec types within that frame, a person cannot: the first
  # letter then stands in the field when the selection arrives, is selected
  # with the suggestion and replaced by the second. 'Wartet nicht' was saved
  # as 'artet nicht' that way (13.11.2026, a run with the machine busy). Focus
  # and selection are set in the same callback, so the focus is the sign that
  # the field is ready.
  def view_name_field
    find('input[name="smart_folder_name"]:focus', wait: 5)
  end
end

RSpec.configure do |config|
  config.include FilterBarHelpers, type: :system
end
