# frozen_string_literal: true

class NeoProjectLayoutHeaderComponent < ViewComponent::Base
  renders_one :title_action
  renders_one :center_content
  renders_one :right_content

  def initialize(
    title:,
    subtitle:,
    project:,
    active_smart_folder: nil,
    selected_item: nil,
    content_open: false,
    context_type: :tickets,
    view_mode: 'table',
    # The gap to whatever follows. 'mb-6' is the page-wide default (a title
    # above a page); a title that stands directly on the list's head passes
    # the head's own gap instead, so the two fugues of that column match.
    margin_bottom: 'mb-6'
  )
    @title = title
    @subtitle = subtitle
    @project = project
    @active_smart_folder = active_smart_folder
    @selected_item = selected_item
    @content_open = content_open
    @context_type = context_type.to_sym
    @view_mode = view_mode
    @margin_bottom = margin_bottom
  end

  private

  attr_reader :title, :subtitle, :project, :active_smart_folder, :selected_item, :content_open, :context_type,
              :view_mode, :margin_bottom

  def computed_title
    title
  end

  def badge_text
    nil
  end
end
