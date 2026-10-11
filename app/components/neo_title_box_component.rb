# frozen_string_literal: true

class NeoTitleBoxComponent < ViewComponent::Base
  renders_one :title_action
  renders_one :center_content
  renders_one :right_content

  def initialize(
    title:,
    variant: :project, # :project or :organisation (resolves subtitle to org name)
    subtitle: nil,
    badge: nil,
    margin_top: nil,
    margin_right: nil,
    margin_left: nil,
    padding_y: nil,
    margin_bottom: 'mb-6'
  )
    @title = title
    @variant = variant
    @subtitle = subtitle
    @badge = badge
    @margin_top = margin_top
    @margin_right = margin_right
    @margin_left = margin_left
    @padding_y = padding_y
    @margin_bottom = margin_bottom
  end

  private

  def resolved_subtitle
    return @subtitle if @subtitle.present?
    return helpers.current_organisation&.name if @variant == :organisation

    nil
  end

  def gradient_style
    '' # Clean, no background gradient
  end

  def wrapper_classes
    [
      @margin_top,
      @margin_right,
      @margin_left,
      @padding_y,
      @margin_bottom
    ].compact.join(' ')
  end
end
