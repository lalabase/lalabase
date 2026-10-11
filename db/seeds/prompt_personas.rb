# frozen_string_literal: true

# Global, operator-curated persona pool for the project-aware chat (Plan §6.1,
# §10). organisation_id: nil → always available, and the guaranteed fallback
# (key "overview" = PromptPersona::DEFAULT_KEY).
#
# All rows here are `system: true`. That flag buys ONE thing, undeletability, via a
# before_destroy on the model that fires everywhere including the operator backend.
# Every seeded row wants it, and the neutral row wants it MOST: the app reads its
# key (the validation exception below hangs on it), and both carrying columns
# (chats, chat_style_preferences) nullify on delete, so removing it would wordlessly
# turn every "no direction" choice into `overview`, the opposite of what those
# people picked, with a re-seed minting a fresh uuid the old references can never
# find again. Retiring one is still possible, via active: false; only destroying is
# shut, and for the global `overview` not even that (guaranteed_default_stays_active).
#
# ⚠️ Do NOT run this on a server whose personas an operator has edited. Every row is
# assigned unconditionally, so a re-run resets labels, fragments, position and
# active to what stands here. To add a single row to a live pool, write the one row.
#
# Idempotent: safe to re-run. Loaded from db/seeds.rb, and runnable standalone:
#   bin/rails runner 'load Rails.root.join("db/seeds/prompt_personas.rb")'
#
# Per-org personas layer on top of this pool (Organisations::PromptPersonasController):
# an org row wins over a global row sharing the same key, see
# PromptPersona.prefer_org_owned.
GLOBAL_PROMPT_PERSONAS = [
  {
    key: PromptPersona::DEFAULT_KEY,
    position: 0,
    labels: { 'de' => 'Überblick', 'en' => 'Overview' },
    prompt_fragments: {
      'de' => 'Der Nutzer möchte das Projekt allgemein verstehen. Gib einen verständlichen ' \
              'Überblick, ordne die Frage in den größeren Zusammenhang ein und bleib auf der ' \
              'Ebene von Zweck und Funktionen, statt einzelne technische Details auszubreiten.',
      'en' => 'The user wants a general understanding of the project. Give an accessible ' \
              'overview, place the question in the bigger picture, and stay at the level of ' \
              'purpose and capabilities rather than spelling out individual technical details.'
    }
  },
  {
    key: 'feature_planning',
    position: 1,
    labels: { 'de' => 'Feature planen', 'en' => 'Plan a feature' },
    prompt_fragments: {
      'de' => 'Der Nutzer plant eine neue Funktion oder Änderung. Hilf, den Wunsch zu schärfen, ' \
              'ordne ihn in die vorhandenen Funktionen ein und benenne betroffene Bereiche und ' \
              'mögliche Auswirkungen in nachvollziehbaren Schritten.',
      'en' => 'The user is planning a new feature or change. Help sharpen the idea, relate it to ' \
              'the existing capabilities, and name the affected areas and likely implications in ' \
              'clear, step-by-step terms.'
    }
  },
  {
    key: 'bug_hunt',
    position: 2,
    labels: { 'de' => 'Fehler verfolgen', 'en' => 'Track down an issue' },
    prompt_fragments: {
      'de' => 'Der Nutzer geht einem Problem oder unerwarteten Verhalten nach. Hilf, das ' \
              'beobachtete Verhalten einzugrenzen, benenne die wahrscheinlich betroffenen Stellen ' \
              'als präzise Referenz und schlage konkrete nächste Schritte zur Klärung vor.',
      'en' => 'The user is investigating a problem or unexpected behaviour. Help narrow down what ' \
              'was observed, point to the parts most likely involved as a precise reference, and ' \
              'suggest concrete next steps to clarify it.'
    }
  },
  {
    # The deliberate opt-out (PromptPersona::NEUTRAL_KEY). Its prompt_fragments are
    # EMPTY on purpose: persona_and_style_block drops blank parts, so picking this
    # yields core prompt + style + guard and no intent at all.
    #
    # It is seeded rather than hand-made on each server because the empty fragment
    # is only legal for THIS key. Leaving it out would put the contract in the code
    # and nothing in the data, so a fresh install would carry a rule with no row
    # that uses it.
    #
    # A high position, so the opt-out sorts after the intents AND after whatever
    # personas an operator adds on their own install. Position is a sort key, not
    # a sequence; the gap is harmless everywhere.
    key: PromptPersona::NEUTRAL_KEY,
    position: 99,
    labels: { 'de' => 'Neutral', 'en' => 'Neutral' },
    prompt_fragments: {}
  }
].freeze

GLOBAL_PROMPT_PERSONAS.each do |attrs|
  persona = PromptPersona.find_or_initialize_by(organisation_id: nil, key: attrs[:key])
  persona.assign_attributes(
    labels: attrs[:labels],
    prompt_fragments: attrs[:prompt_fragments],
    position: attrs[:position],
    active: true,
    system: true
  )
  persona.save!
end
