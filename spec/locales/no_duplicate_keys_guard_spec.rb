# frozen_string_literal: true

require 'rails_helper'
require 'psych'

# Guard: no duplicate keys within a single mapping in any locale YAML file.
#
# Why this exists (the silent-drift bug class it prevents):
# YAML keeps only the LAST of two same-level keys. A duplicated key therefore
# DELETES the earlier sibling's whole subtree at parse time — with no error and
# no warning. In June 2026 two duplicated `flash:` children in
# controllers.{de,en}.yml silently dropped flash.invitations.{sent,deleted},
# flash.chats.{created,updated,deleted,delete_error} and
# flash.permissions.{updated,account_admin_all}: every t() call returned
# "translation missing" while the keys looked perfectly present in the file.
#
# i18n-tasks cannot catch this: it inspects the already-merged Ruby hash, so the
# discarded keys are invisible to it. Only a scan of the RAW parse tree (before
# the merge collapses the collision) can see two siblings sharing a key.
#
# This walks the Psych node tree and flags any mapping listing the same key
# twice. Merge keys ("<<") are exempt — repeating them is valid YAML semantics
# (Psych merges all of them), though no locale file uses them today.
RSpec.describe 'Locale YAML duplicate-key guard' do
  MERGE_KEY = '<<'

  LOCALE_FILES = Dir[Rails.root.join('config/locales/**/*.yml')].sort.freeze

  # Returns "dotted.key.path (line N)" for every key that appears more than once
  # inside the same mapping, anywhere in the document.
  def duplicate_keys_in(path)
    offenders = []

    visit = lambda do |node, trail|
      case node
      when Psych::Nodes::Mapping
        seen = {}
        node.children.each_slice(2) do |key_node, value_node|
          key = key_node.respond_to?(:value) ? key_node.value : key_node.to_s
          offenders << "#{(trail + [key]).join('.')} (line #{key_node.start_line + 1})" if key != MERGE_KEY && seen[key]
          seen[key] = true
          visit.call(value_node, trail + [key])
        end
      when Psych::Nodes::Sequence, Psych::Nodes::Document, Psych::Nodes::Stream
        node.children.each { |child| visit.call(child, trail) }
      end
    end

    visit.call(Psych.parse_stream(File.read(path)), [])
    offenders
  end

  # Sanity: a glob that silently matches nothing would make the guard vacuously
  # green and stop protecting anything.
  it 'finds locale files to check' do
    expect(LOCALE_FILES).not_to be_empty
  end

  LOCALE_FILES.each do |path|
    rel = Pathname.new(path).relative_path_from(Rails.root).to_s

    it "has no duplicate keys within any mapping: #{rel}" do
      offenders = duplicate_keys_in(path)

      expect(offenders).to be_empty, <<~MSG
        Duplicate YAML keys in #{rel}:

        #{offenders.map { |o| "  - #{o}" }.join("\n")}

        YAML keeps only the LAST sibling with a given key, so the earlier block
        and its entire subtree are silently discarded at parse time (this is how
        translations go "missing" while still appearing in the file). Merge the
        duplicated blocks into one and delete the redundant key.
      MSG
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-FILE check: the same leaf key defined in TWO files with DIFFERING
  # values. i18n merges files load-order-wise (the later file wins), so such a
  # pair is a silent override whose winner flips when a file is renamed or
  # moved. Identical-value duplicates are mere redundancy and out of scope.
  #
  # The allowlist pins the pre-existing pairs (Devise/SmartFolder wording
  # variants, measured 2026-07-13). Shrink-only: resolve a pair by deleting
  # the losing copy, then remove its key here (the stale-entry test enforces it).
  # ---------------------------------------------------------------------------
  def cross_file_differing_allowlist
    %w[
      en.devise.confirmations.confirmed
      en.devise.confirmations.send_instructions
      en.devise.confirmations.send_paranoid_instructions
      en.devise.failure.inactive
      en.devise.failure.timeout
      en.devise.failure.unauthenticated
      en.devise.failure.unconfirmed
      en.devise.mailer.confirmation_instructions.subject
      en.devise.mailer.email_changed.subject
      en.devise.mailer.password_change.subject
      en.devise.omniauth_callbacks.failure
      en.devise.omniauth_callbacks.success
      en.devise.passwords.no_token
      en.devise.passwords.send_instructions
      en.devise.passwords.send_paranoid_instructions
      en.devise.registrations.destroyed
      en.devise.registrations.signed_up
      en.devise.registrations.signed_up_but_inactive
      en.devise.registrations.signed_up_but_locked
      en.devise.registrations.signed_up_but_unconfirmed
      en.devise.registrations.update_needs_confirmation
      en.devise.unlocks.send_instructions
      en.devise.unlocks.send_paranoid_instructions
      en.errors.messages.confirmation_period_expired
      en.errors.messages.not_saved.one
      en.errors.messages.not_saved.other
    ]
  end

  # Leaf key => [[file, value], ...] across all locale files, for keys that
  # appear in more than one file with more than one distinct value.
  def cross_file_differing_keys
    values = Hash.new { |h, k| h[k] = [] }

    LOCALE_FILES.each do |path|
      data = YAML.unsafe_load_file(path)
      next unless data.is_a?(Hash)

      walk = lambda do |node, trail|
        node.each do |key, value|
          full = trail + [key.to_s]
          value.is_a?(Hash) ? walk.call(value, full) : values[full.join('.')] << [path, value]
        end
      end
      walk.call(data, [])
    end

    values.select do |_, entries|
      entries.map(&:first).uniq.size > 1 && entries.map(&:last).uniq.size > 1
    end
  end

  it 'defines no leaf key in two files with differing values (silent cross-file override)' do
    offenders = cross_file_differing_keys.reject { |key, _| cross_file_differing_allowlist.include?(key) }

    expect(offenders.keys).to be_empty, <<~MSG
      Same key, different values in multiple locale files (later-loaded file wins silently):

      #{offenders.map { |k, e| "  - #{k}\n#{e.map { |f, v| "      #{Pathname.new(f).relative_path_from(Rails.root)}: #{v.inspect[0, 90]}" }.join("\n")}" }.join("\n")}

      Keep exactly ONE owner per key: delete the losing copy (check which file
      wins at runtime first) or align the values.
    MSG
  end

  it 'keeps the cross-file allowlist shrink-only (resolved pairs must be removed)' do
    stale = cross_file_differing_allowlist - cross_file_differing_keys.keys

    expect(stale).to be_empty, <<~MSG
      These allowlisted keys no longer collide — remove them from the allowlist:
      #{stale.map { |k| "  - #{k}" }.join("\n")}
    MSG
  end
end
