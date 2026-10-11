# frozen_string_literal: true

# What: Guard spec — every `encrypts` column in the app must be covered by
#   exactly one TokenReencryptable registration per table.
# Why: rake encryption:reencrypt_tokens is the ONLY thing that moves existing
#   rows under a new primary key (backfill + rotation). Its first version
#   covered 3 of 6 encrypted columns — the initializer's own header listed all
#   six, and nothing complained. After a rotation completes (previous scheme
#   removed), every uncovered row is permanently unreadable; until then it
#   stays under the retired key. This guard turns "the task covers everything"
#   from a review observation into an invariant: add `encrypts`, and this spec
#   fails until the column is registered.
# Contract:
#   * every (table, encrypted column) pair appears in TokenReencryptable.registry
#   * exactly one owner model per table (shadow models share tables — a second
#     registration would sweep rows twice)
#   * no stale registration for columns that are no longer encrypted
#   * every model sharing an encrypted table declares the SAME encrypted column
#     set (per-model symmetry — the per-table union above cannot see a shadow
#     model that writes one column as cleartext)
require 'rails_helper'

RSpec.describe 'TokenReencryptable coverage guard' do
  before { Rails.application.eager_load! } # registry + descendants need all models loaded

  # Framework classes that declare `encrypts` on their own, independent of this
  # app. Excluded ONLY together with a companion example proving the app does
  # not use the feature — the moment it does, that example fails and forces a
  # registration/rotation decision for the table.
  let(:framework_encrypted_classes) { %w[ActionText::EncryptedRichText] }

  # (table name => encrypted column set) across ALL models — ActiveRecord::Base
  # descendants, not ApplicationRecord, so a model bypassing the app base class
  # cannot slip past the guard. Shadow models (Admin::*) merge into their
  # table's entry, so declaring `encrypts` on only one side of a shadow pair
  # still counts for the shared table. skip_class? guards name.nil? and
  # encrypted_attributes BEFORE table_name: anonymous spec-built classes
  # (name = nil) can blow up on table_name, and classes without encrypts must
  # be skipped before ever asking for it.
  def encrypted_columns_by_table
    ActiveRecord::Base.descendants.each_with_object({}) do |klass, map|
      next if skip_class?(klass)

      (map[klass.table_name] ||= Set.new).merge(klass.encrypted_attributes.map(&:to_sym))
    end
  end

  # Anonymous classes (name = nil) are spec scaffolding — the rotation
  # roundtrip spec builds `Class.new(ApplicationRecord)` readers that would
  # otherwise leak into descendants and make this guard's result depend on
  # spec order and garbage collection.
  def skip_class?(klass)
    klass.abstract_class? ||
      klass.name.nil? ||
      framework_encrypted_classes.include?(klass.name) ||
      klass.encrypted_attributes.blank? ||
      klass.table_name.blank?
  end

  def registered_columns_by_table
    TokenReencryptable.registry.each_with_object({}) do |(class_name, columns), map|
      table = class_name.constantize.table_name
      raise "duplicate TokenReencryptable registration for table #{table}" if map.key?(table)

      map[table] = columns.map(&:to_sym).to_set
    end
  end

  it 'does not use encrypted rich text (justifies excluding ActionText::EncryptedRichText above)' do
    # ActionText::EncryptedRichText carries `encrypts :body` as framework code.
    # As long as no `has_rich_text ... encrypted: true` exists in the app, the
    # table holds no encrypted rows and needs no rotation sweep. If this ever
    # matches, the exclusion above loses its justification: register a sweep
    # for action_text_rich_texts (or extend the concern) before shipping.
    offenders = Dir[Rails.root.join('app/**/*.rb')].filter_map do |file|
      file if File.read(file).match?(/has_rich_text[^\n]*encrypted:\s*true/)
    end

    expect(offenders).to be_empty, <<~MSG
      Encrypted rich text is now in use, but action_text_rich_texts is excluded
      from the reencrypt coverage guard. Add a rotation sweep for that table
      and remove the exclusion. Offenders:
      #{offenders.join("\n")}
    MSG
  end

  it 'registers every encrypted column on exactly one model per table' do
    expect(registered_columns_by_table).to eq(encrypted_columns_by_table), <<~MSG
      TokenReencryptable.registry does not match the `encrypts` declarations.
      Every encrypted column must be swept by rake encryption:reencrypt_tokens —
      an uncovered column silently stays under the old key and becomes
      unreadable once a rotation completes. Register it via
      `include TokenReencryptable` + `reencrypts_tokens :column` on the ONE
      owner model of its table (mind shadow models: one registration per table).
    MSG
  end

  it 'declares identical encrypted column sets on every model sharing a table (shadow symmetry)' do
    # The per-table UNION above is structurally blind here: a shadow model
    # missing one `encrypts` (or all of them) still "counts" for the table via
    # its twin — but every write through the shadow stores that column as
    # CLEARTEXT, which the runtime model then treats as ciphertext-or-legacy.
    # Compare each model's OWN declaration set against its table's union —
    # deliberately including models with ZERO declarations, the worst case —
    # so any drift names the model that forgot a declaration.
    union_by_table = encrypted_columns_by_table

    asymmetric = ActiveRecord::Base.descendants.each_with_object({}) do |klass, map|
      next if klass.abstract_class? || klass.name.nil? || framework_encrypted_classes.include?(klass.name)
      next unless union_by_table.key?(klass.table_name)

      union = union_by_table.fetch(klass.table_name)
      own = klass.encrypted_attributes.map(&:to_sym).to_set
      map["#{klass.name} (#{klass.table_name})"] = "declares #{own.to_a.sort}, table has #{union.to_a.sort}" if own != union
    end

    expect(asymmetric).to be_empty, <<~MSG
      Models sharing a table disagree about which columns are encrypted — the
      model(s) below write the missing column(s) as CLEARTEXT while their twin
      expects ciphertext. Add the missing `encrypts` declaration(s):
      #{asymmetric.map { |k, v| "#{k}: #{v}" }.join("\n")}
    MSG
  end

  # Mutation probes for the guard's own machinery: both protections live in
  # HELPERS, not assertions, so a refactor could disarm them while every
  # example above stays green.
  describe 'guard machinery' do
    it 'raises on a second registration for the same table (double sweep)' do
      registry = {
        'ProjectRepository' => [:access_token].freeze,
        'Admin::AiCredential' => [:access_token].freeze,
        'AiCredential' => [:access_token].freeze # same table as the admin shadow
      }
      allow(TokenReencryptable).to receive(:registry).and_return(registry)

      expect { registered_columns_by_table }.to raise_error(/duplicate TokenReencryptable registration/)
    end

    it 'fails the coverage comparison when a registered column is dropped (not vacuously green)' do
      mutated = TokenReencryptable.registry.dup
      mutated['ProjectRepository'] = [:access_token].freeze # webhook_secret dropped
      allow(TokenReencryptable).to receive(:registry).and_return(mutated)

      expect(registered_columns_by_table).not_to eq(encrypted_columns_by_table)
    end
  end
end
