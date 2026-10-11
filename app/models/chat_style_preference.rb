# frozen_string_literal: true

# == Schema Information
#
# Table name: chat_style_preferences
#
#  id                :uuid             not null, primary key
#  length            :integer          default(2), not null
#  technicality      :integer          default(2), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  organisation_id   :uuid             not null
#  prompt_persona_id :uuid
#  user_id           :uuid             not null
#
# Indexes
#
#  index_chat_style_preferences_on_organisation_id_and_user_id  (organisation_id,user_id) UNIQUE
#  index_chat_style_preferences_on_prompt_persona_id            (prompt_persona_id)
#  index_chat_style_preferences_on_user_id                      (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (prompt_persona_id => prompt_personas.id) ON DELETE => nullify
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
# 2026-07-19: the levels used to be adjusted RELATIVELY (a "shorter"/"simpler"
# pill nudged by ±1, clamped). The pills now show all three steps at once and set
# the level directly, so the nudge map, the clamping and the one-off style
# parameter threaded through ChatResponseJob are gone — a three-step control
# needs the direct jump (1 → 3 in one click), which a delta cannot express.
class ChatStylePreference < ApplicationRecord
  # belongs_to :prompt_persona + the "may this persona be attached" rule (own org
  # or the global pool, active only), shared with Chat so ONE place decides it.
  include PromptPersonaSelectable

  acts_as_tenant(:organisation)
  belongs_to :user

  LEVELS  = (1..3)
  DEFAULT = { technicality: 2, length: 2 }.freeze
  # The settable dimensions. Whitelist for set_for! and the controller — keeps an
  # arbitrary params value from reaching public_send/[]= as a column name.
  DIMENSIONS = %w[technicality length].freeze

  validates :technicality, :length, inclusion: { in: LEVELS.to_a }
  # Mirrors the DB unique index for a friendly error instead of RecordNotUnique.
  validates :user_id, uniqueness: { scope: :organisation_id }

  # Resolve-or-default (lazy, READ-ONLY): with no stored row, returns an
  # UNPERSISTED record carrying the neutral 2/2 default (Plan §6.2: no mandatory
  # insert). Used by the job to read a level without ever writing one. Never
  # persists. Runs under the caller's tenant (the job's with_tenant block).
  def self.resolve_for(user:, organisation:)
    find_by(user: user, organisation: organisation) ||
      new(user: user, organisation: organisation, **DEFAULT)
  end

  # Persistent set path (controller). Atomic + idempotent against the
  # double-click race on the [organisation_id, user_id] unique index: two
  # near-simultaneous pill clicks would each build a fresh unpersisted row and
  # both INSERT → the second raises RecordNotUnique (a 500). find_or_create_by
  # can itself lose the race between SELECT and INSERT, so retry once: on retry
  # the row now exists and find_or_create_by returns it for a plain UPDATE.
  #
  # The retry does NOT double-apply anything: RecordNotUnique is raised by the
  # INSERT inside find_or_create_by!, BEFORE set_level! ever runs, so the first
  # attempt changes nothing. Only the retry (which finds the existing row) calls
  # set_level!. Retry is the right tool here (vs. rescuing in the controller)
  # because the race is a pure persistence concern; keeping it in the model means
  # every caller is race-safe without repeating the rescue. (The set is
  # idempotent, so a retry would be harmless either way — unlike the ±1 nudge it
  # replaced, where a double-apply WOULD have been wrong.)
  #
  # Caller-transaction safety (checked for the actor seam, F2): callers may hold
  # an open transaction (Actors::SetChatStyle runs this inside the BaseActor
  # txn). That is safe WITHOUT extra hardening here, because Rails 8's
  # find_or_create_by! delegates its create attempt to create_or_find_by!, which
  # wraps the INSERT in transaction(requires_new: true) — a savepoint — and
  # resolves a lost race via `.lock.find_by!`. A unique violation therefore
  # never poisons the surrounding transaction ("current transaction is
  # aborted"); pinned by spec under an open caller txn. The local rescue/retry
  # stays as a residual net for RecordNotUnique surfacing outside that path.
  def self.set_for!(user:, organisation:, dimension:, level:)
    row_for!(user: user, organisation: organisation).set_level!(dimension, level)
  end

  # Sets the standing persona choice (the assistant's settings menu). nil clears
  # it back to "the organisation's default", which is what an untouched row means.
  #
  # Goes through the SAME row_for! as the levels above rather than repeating the
  # find_or_create_by/retry shape: two copies of a race fix drift, and only one of
  # them gets the next correction.
  def self.set_persona!(user:, organisation:, prompt_persona_id:)
    row_for!(user: user, organisation: organisation).set_persona!(prompt_persona_id)
  end

  # ONE owner of "the requesting person's preference row in this org, race-safely".
  # Everything above the comment on set_for! (why find_or_create_by!, why the
  # retry, why it is safe inside a caller's transaction) applies here, which is
  # exactly why it lives in one method now.
  def self.row_for!(user:, organisation:)
    find_or_create_by!(user: user, organisation: organisation)
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  # Sets ONE dimension to an absolute level and persists. An unknown dimension or
  # an out-of-range level is a silent no-op WITHOUT a save — defense in depth
  # behind the controller whitelist, so a crafted param can neither write a
  # foreign column nor store a level the prompt lookup has no I18n key for.
  def set_level!(dimension, level)
    dimension = dimension.to_s
    level = Integer(level, exception: false)
    return self unless DIMENSIONS.include?(dimension) && LEVELS.include?(level)

    self[dimension] = level
    save!
    self
  end

  # Stores the persona choice. A blank value clears it (back to the org default).
  # An id the person may not use is refused by the model validation from
  # PromptPersonaSelectable, so this raises rather than storing it -- the
  # controller has already checked the same id against the offered pool, and a
  # value that gets past both is a bug worth hearing about.
  def set_persona!(prompt_persona_id)
    self.prompt_persona_id = prompt_persona_id.presence
    save!
    self
  end
end
