# frozen_string_literal: true

# The preferences are one page of sections (user_preferences/edit). A section's anchor
# has one owner here: the page writes it as the section's id, and every link into the
# page asks for the same word (`preferences_section_path`).
module UserPreferencesHelper
  def preferences_section_anchor(key)
    "section-#{key}"
  end

  # The preferences page, scrolled to one section: the link of a hint elsewhere in the
  # application ("change the session length", "choose the AI mode").
  def preferences_section_path(key)
    edit_user_preferences_path(anchor: preferences_section_anchor(key))
  end
end
