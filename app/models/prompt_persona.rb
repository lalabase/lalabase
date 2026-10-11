# frozen_string_literal: true

# == Schema Information
#
# Table name: prompt_personas
#
#  id               :uuid             not null, primary key
#  active           :boolean          default(TRUE), not null
#  key              :string           not null
#  labels           :jsonb            not null
#  position         :integer          default(0), not null
#  prompt_fragments :jsonb            not null
#  system           :boolean          default(FALSE), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  organisation_id  :uuid
#
# Indexes
#
#  index_prompt_personas_on_global_key   (key) UNIQUE WHERE (organisation_id IS NULL)
#  index_prompt_personas_on_org_and_key  (organisation_id,key) UNIQUE WHERE (organisation_id IS NOT NULL)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
# A selectable chat persona: the *intent* the user brings to a chat (overview,
# planning a feature, tracking down an issue). Its `prompt_fragments` are
# injected into the chat system prompt to bias HOW the assistant answers, on
# top of the always-on non-technical core prompt (Plan §3, §6.1).
class PromptPersona < ApplicationRecord
  # The default persona key. A chat with no explicit persona
  # (chats.prompt_persona_id NULL) falls back to this one. It is always seeded
  # globally with system: true, so it is the guaranteed fallback (Plan §6.3,
  # open question 4).
  DEFAULT_KEY = 'overview'

  # The neutral persona: the one row whose EMPTY prompt fragment is the point.
  # Picking it means "answer without aiming at anything", so persona_and_style_block
  # composes core prompt + style directives + injection guard and nothing else.
  #
  # A key rather than a new column, for the same reason DEFAULT_KEY is one: this
  # model already lets a key carry a contract, and a second one beside it is a
  # pattern instead of a special case. It also keeps the override flow intact, so an
  # organisation can publish its own `neutral` row and put something in it.
  #
  # ⚠️ Empty and "take no particular direction" are NOT the same thing. Empty means
  # the block is absent from the prompt. A sentence means the model gets an
  # instruction like any other, and models told to be neutral tend to hedge rather
  # than to stop aiming. The empty row is the honest neutral; filling it is allowed
  # (see the validation below) but it stops being this.
  NEUTRAL_KEY = 'neutral'

  # Deliberately NOT acts_as_tenant. The pool is two-layered: global rows
  # (organisation_id NULL — the seeded system defaults) PLUS optional per-org
  # rows. acts_as_tenant's default scope (organisation_id = current_tenant)
  # would hide every global row, so scoping is explicit via `available_for`
  # instead (Plan §6.1).
  belongs_to :organisation, optional: true
  # No `has_many :chats` association: nothing reads persona.chats, and deleting
  # a persona is handled by the FK (on_delete: :nullify, set in the migration) —
  # an app-level dependent: :nullify would run through Chat's acts_as_tenant
  # default scope and skip chats outside the current tenant.

  validates :key, presence: true
  # Mirrors the two partial unique indexes for friendly errors. scope:
  # :organisation_id treats NULL as its own scope, matching the global index.
  validates :key, uniqueness: { scope: :organisation_id }
  # ONE rule per field, each owning the whole question "is there content here".
  #
  # These replaced a `presence: true` pair plus a second custom check. presence
  # only rejects an EMPTY hash ({}); a hash of all-blank strings ({"de"=>"",
  # "en"=>""}) walks past it and yields a nameless / intent-less (inert) persona,
  # which is exactly what a form with empty fields submits. Two rules per field
  # meant the neutral exception had to be written twice, and the fragment rule's
  # early return then sat in the middle of the labels rule, where its POSITION
  # silently decided whether a nameless row could be saved.
  #
  # Split this way there is no shared method, so no order to get wrong and no
  # second place to remember the exception.
  validate :labels_have_content
  # The one exception in the model: on the neutral row an empty fragment IS the
  # instruction (NEUTRAL_KEY). Labels stay required even there, because a picker
  # entry nobody can name is the inert-persona problem this rule exists for.
  validate :fragments_have_content, unless: :neutral?

  # The global system "overview" persona is every chat's guaranteed fallback
  # (see DEFAULT_KEY / default_for). Deactivating it would silently strip the
  # default persona fragment from every chat that did not pick one — an org-wide
  # degradation with no error surface. The operator backend (v2) exposes an
  # `active` toggle for retiring OTHER personas, so this one row is guarded at the
  # model layer (defense in depth: it holds no matter which controller, console,
  # or rake task flips the flag). Per-org "overview" overrides are intentionally
  # NOT guarded — if one goes inactive, default_for falls back to the global row.
  validate :guaranteed_default_stays_active

  before_destroy :prevent_system_destroy

  # Authorization boundary (used by PromptPersonaPolicy::Scope): the personas an
  # org may ever use = its own rows plus the global pool, active only, ordered
  # for display. No key-dedup here — that is presentation, handled by
  # `prefer_org_owned` (Plan §6.1).
  scope :available_for, lambda { |organisation|
    where(organisation_id: [nil, organisation&.id])
      .where(active: true)
      .order(:position, :key)
  }

  # Collapses a set of personas to one row per key, letting an org-owned row win
  # over a global row that shares the same key (Plan §6.1 "org override wins").
  # This is the picker dedup: the controller applies it to the policy-scoped pool
  # (`prefer_org_owned(policy_scope(PromptPersona))`) and `default_for` applies it
  # to `available_for`. It DOES collapse in practice since the per-org CRUD shipped
  # (Organisations::PromptPersonasController, whose ?from=<key> flow copies a
  # global row's key on purpose), so anything that asks "which persona is in
  # effect" has to ask through here and not through `available_for`.
  # Takes any persona Enumerable, returns an Array (not a relation).
  def self.prefer_org_owned(personas)
    personas
      .group_by(&:key)
      .map { |_key, rows| rows.max_by { |row| row.organisation_id ? 1 : 0 } }
      .sort_by { |persona| [persona.position, persona.key] }
  end

  # The fallback persona for a chat with no explicit choice. Goes through
  # prefer_org_owned so an org's own `overview` wins over the global one. Returns
  # nil only if the global pool was never seeded — callers MUST degrade
  # gracefully (the chat then runs on the core prompt alone, still non-technical).
  def self.default_for(organisation)
    pickable_for(organisation).find { |persona| persona.key == DEFAULT_KEY }
  end

  # The personas an organisation may actually pick from: its own rows plus the
  # global pool, active only, one row per key with the org's override winning.
  #
  # ONE owner of that set, because three callers now need exactly it -- default_for
  # above, the assistant's settings picker, and the check the write path runs the
  # submitted id against. The offered list and the accepted list being the same
  # expression is the point: where they drift, a picker offers something the
  # controller then refuses.
  #
  # Identical to what PromptPersonaPolicy::Scope resolves to (available_for), so a
  # caller with no controller context around it can ask this directly.
  def self.pickable_for(organisation)
    prefer_org_owned(available_for(organisation))
  end

  # The row whose empty fragment is deliberate (see NEUTRAL_KEY). An org override
  # sharing the key is neutral too, which is what makes the override flow usable
  # here at all.
  def neutral?
    key == NEUTRAL_KEY
  end

  # Admin-facing display label in the requested locale.
  def label(locale)
    localized(labels, locale)
  end

  # The intent text injected into the chat system prompt, rendered in the chat's
  # pinned language (the caller passes chat.language).
  def prompt_fragment(locale)
    localized(prompt_fragments, locale)
  end

  private

  # Per-locale jsonb lookup with a sane fallback chain: requested locale → the
  # canonical default language → any present value. Keeps a persona an operator
  # only filled in one language from rendering blank.
  def localized(store, locale)
    values = store || {}
    values[locale.to_s].presence ||
      values[Lalabase::Languages::DEFAULT].presence ||
      values.values.find(&:present?)
  end

  # Plan §14: seeded system personas (the global defaults) must not be deletable
  # per-org. `system?` is the ActiveRecord boolean query method (safe — Kernel
  # has no `system?`, unlike the bare `system`).
  def prevent_system_destroy
    return unless system?

    errors.add(:base, :system_persona_undeletable)
    throw(:abort)
  end

  # See the `validate :guaranteed_default_stays_active` comment above for the WHY.
  # Narrowly scoped to the single global system row whose key is DEFAULT_KEY, so it
  # never interferes with retiring any other persona.
  def guaranteed_default_stays_active
    return if active?
    return unless system? && organisation_id.nil? && key == DEFAULT_KEY

    errors.add(:base, :default_persona_must_stay_active)
  end

  # See `validate :labels_and_fragments_have_content`. Guards the present-but-blank
  # case the presence validation cannot (a non-empty hash whose values are all "").
  # `to_h` covers all three empty shapes in one expression: nil (an in-memory row
  # before the column default applies), {} and a hash of blank strings.
  def labels_have_content
    errors.add(:labels, :blank) if labels.to_h.values.none?(&:present?)
  end

  def fragments_have_content
    errors.add(:prompt_fragments, :blank) if prompt_fragments.to_h.values.none?(&:present?)
  end
end
