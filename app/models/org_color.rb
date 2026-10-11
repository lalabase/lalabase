# frozen_string_literal: true

# Org recognition color (phase 3 of the token-layer roadmap) — pure data + logic,
# DELIBERATELY without DB access: the state is passed in from outside, so that these
# rules are unit-testable without the Rails stack/fixtures (see spec/models/org_color_spec.rb).
#
# Purpose: anyone working in multiple orgs should recognize at a glance which one they are in.
# Each org gets a subtle color for that. Control is PER USER (everyone their own view) —
# only because of that does "turn color off" make any sense at all (a global "off" would be for everyone).
#
# Three states per (user, org), stored in users.preferences['sidebar_colors'][org_id]:
#   - absent (nil)   -> "automatic": the system assigns a palette color
#                       (see User::OrgColorSettings#ensure_defaults!).
#   - OFF            -> deliberately turned off: NO color signal.
#   - "#rrggbb"      -> concrete color (auto-assigned OR chosen by the user).
#
# WHY a dedicated OFF sentinel instead of simply nil for "off":
# nil == absent == "never decided" and triggers the auto-assignment. "Off" is,
# however, a deliberate decision and must NOT be auto-overwritten. So both cases
# must remain distinguishable -> a third, explicit value.
module OrgColor
  # Sentinel for "deliberately off". Deliberately a string (not a symbol/nil), because the value
  # lands raw in the JSONB preferences and comes back as a string when read.
  OFF = 'off'

  # Curated, on-palette pastels — the ONLY color source (the /appearance picker
  # and the auto-assignment also draw from here; no second list anymore). Values == the
  # historical sidebar colors -> already stored user choices remain valid.
  # Light enough for black text (logo chip) and recognizable as an edge line/banderole.
  PALETTE = [
    { key: 'sand',     hex: '#fef3c7' },
    { key: 'mint',     hex: '#d1fae5' },
    { key: 'sky',      hex: '#dbeafe' },
    { key: 'lavender', hex: '#ede9fe' },
    { key: 'rose',     hex: '#ffe4e6' },
    { key: 'peach',    hex: '#ffedd5' },
    { key: 'cyan',     hex: '#cffafe' },
    { key: 'lime',     hex: '#ecfccb' }
  ].freeze

  # Only the hex values, in palette order (= assignment order).
  HEXES = PALETTE.map { |c| c[:hex] }.freeze

  # Is value a valid color hex (#rrggbb)? Cleanly separates "real color" from OFF/nil,
  # so that the OFF sentinel is never accidentally treated as a CSS color.
  def self.hex?(value)
    value.is_a?(String) && value.match?(/\A#\h{6}\z/)
  end

  # Next free palette color that has not been assigned yet. If ALL are assigned
  # (more orgs than palette colors), it rotates deterministically instead of returning nil
  # -> better a repeated color than no distinction at all. taken may contain non-hex
  # (OFF/nil) values; those are ignored.
  def self.next_color(taken)
    taken_hexes = Array(taken).select { |v| hex?(v) }
    free = HEXES - taken_hexes
    return free.first if free.any?

    HEXES[taken_hexes.size % HEXES.size]
  end

  # Pure auto-assignment: returns a NEW map org_id => value. Every org without an
  # entry gets the next free color; orgs already decided (hex OR OFF)
  # remain untouched (idempotency + "off" is never overwritten). Testable without a DB.
  def self.assign_defaults(existing_by_org_id:, org_ids:)
    result = existing_by_org_id.dup
    taken = result.values
    org_ids.each do |org_id|
      next if result.key?(org_id) # already decided -> don't touch

      color = next_color(taken)
      result[org_id] = color
      taken += [color]
    end
    result
  end

  # The ONE place for the visibility rules, so that <html>, sidebar and org selector
  # make exactly the same decision (no triple-copied logic). Returns the
  # hex to display or nil:
  #   - <2 orgs  -> nil  (a single org needs no distinguishing signal)
  #   - OFF      -> nil  (deliberately off)
  #   - hex      -> hex
  #   - else     -> nil  (absent; after auto-assignment effectively no longer the case)
  def self.effective_color(setting:, org_count:)
    return nil if org_count < 2
    return nil if setting == OFF
    return setting if hex?(setting)

    nil
  end
end
