# frozen_string_literal: true

# Org recognition color — view binding (Phase 3). Converts the effective color into the
# CSS variable form (raw RGB channels for `rgb(var(--brand) / <alpha-value>)`) and
# returns the inline override for the <html> tag. The source is ALWAYS the resolver
# (User::OrgColorSettings#effective_color) -> the ≥2 gate and the OFF sentinel are
# decided centrally there, NOT duplicated here.
module BrandHelper
  # "#2563eb" -> "37 99 235". to_i(16) (explicitly base 16) instead of String#hex — more readable.
  # nil/invalid -> nil (the caller falls back to the :root default).
  def hex_to_rgb_channels(hex)
    digits = hex.to_s.delete('#')
    return nil unless digits.match?(/\A\h{6}\z/)

    r = digits[0, 2].to_i(16)
    g = digits[2, 2].to_i(16)
    b = digits[4, 2].to_i(16)
    "#{r} #{g} #{b}"
  end

  # Inline style value "--brand: r g b;" for the current user in the current org,
  # otherwise nil (no override -> :root default = lime-200 applies -> no recognition signal).
  def brand_style_for(user, organisation)
    return nil unless user && organisation

    rgb = hex_to_rgb_channels(user.org_colors.effective_color(organisation))
    rgb && "--brand: #{rgb};"
  end
end
