# frozen_string_literal: true

class User < ApplicationRecord
  # === Name display (doc/user_display_name_avatar_plan.md, S1) ===
  # THE single owner of how a user's name is rendered. Consolidates what used
  # to live three times in parallel (User#full_name/#display_name, the
  # ApplicationHelper user_initials chain, Admin::User#avatar_initials) so
  # every render site computes the same string for the same user.
  #
  # WHERE the setting applies (surface register + rules, guard-enforced):
  # docs/dokumentation/namensanzeige_flaechenregister.md
  #
  # The MODE comes from the VIEWER's preference
  # (User::PreferenceStore#name_display_mode), not from the displayed user:
  # the setting controls how all names look FOR ME. Render seams:
  #   - chip/identity contexts: Neo::Users::NameComponent (can render 'circle')
  #   - text contexts (prose, comma-joins, selects, mailers):
  #     ApplicationHelper#viewer_display_name -> display_name(mode:), where
  #     'circle' deliberately reads as the full name — a circle has no text form.
  module NameDisplay
    extend ActiveSupport::Concern

    # Raw "first last" pair, unstripped — long-standing public API, many call
    # sites (incl. mailers) rely on it. Prefer display_name for anything
    # user-facing: it strips and falls back to the email local part.
    def full_name
      "#{first_name} #{last_name}"
    end

    # The user-facing name in one of the display modes. Mode strings come from
    # User::PreferenceStore::NAME_DISPLAY_MODES; anything unknown (and
    # 'circle', which has no text form) renders as the full name, so a stale
    # stored value can never blank out a name.
    # Abbreviations only make sense with BOTH name parts — a user with a single
    # name part (or none) gets that part in full / the email fallback.
    def display_name(mode: User::PreferenceStore::NAME_DISPLAY_DEFAULT)
      return default_display_name unless first_name.present? && last_name.present?

      case mode.to_s
      when 'first_last_initial' then "#{first_name.strip} #{name_initial(last_name)}"
      when 'initial_last' then "#{name_initial(first_name)} #{last_name.strip}"
      else default_display_name
      end
    end

    # Two upcased letters for the circle rendering. First letters of both name
    # parts when present; otherwise the first two characters of whatever
    # identifies the user (single name part, or the email local part).
    def initials
      if first_name.present? && last_name.present?
        "#{first_name.strip[0]}#{last_name.strip[0]}".upcase
      else
        parts = default_display_name.split
        if parts.length >= 2
          "#{parts.first[0]}#{parts.last[0]}".upcase
        else
          default_display_name[0..1].to_s.upcase
        end
      end
    end

    private

    # Bit-identical to the historic User#display_name: stripped full name,
    # email local part when both name parts are blank.
    def default_display_name
      full_name.strip.presence || email.split('@').first
    end

    def name_initial(part)
      "#{part.strip[0].upcase}."
    end
  end
end
