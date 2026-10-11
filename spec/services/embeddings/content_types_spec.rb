# frozen_string_literal: true

# What: Guard — Embeddings::ContentTypes is complete and honest against the models.
# Type: Registry guard, DERIVED from the models rather than transcribed.
# Why (philosophy): The registry is the one owner of "which types are embedded", and its
#   failure mode is silence. A model that grows fragments without an entry is counted
#   nowhere; an entry naming a type that has no fragments reports 0/0 for ever (the sync
#   page counted 'Document' fragments for months, and there were none). Both are caught
#   here by reading the MODELS, so the list is never checked against a copy of itself.
# Contract: registered ⟺ declares `has_many :fragments, as: :fragmentable`; key = table =
#   the model's table; every registered table carries the two state columns; every
#   entry's atoms are runnable SQL; an unknown key resolves to nil.

require 'rails_helper'

RSpec.describe Embeddings::ContentTypes do
  def fragmentable?(model)
    reflection = model.reflect_on_association(:fragments)
    reflection.present? && reflection.options[:as] == :fragmentable
  end

  # The inverse direction is the one that matters: this is derived from the models, so a
  # tenth fragmentable model turns it red until it is registered — and 'Document', which
  # has no fragments, can never be.
  it 'registers every model that has fragments, and nothing else' do
    Rails.application.eager_load!
    fragmentable = ApplicationRecord.descendants
                                    .select { |model| model.base_class == model && fragmentable?(model) }
                                    .map(&:name)

    expect(described_class.entries.map(&:model_name)).to match_array(fragmentable)
  end

  it 'names each entry after its table, and the table after the model' do
    described_class.entries.each do |entry|
      expect(entry.key.to_s).to eq(entry.table), entry.key.inspect
      expect(entry.model.table_name).to eq(entry.table), entry.key.inspect
    end
  end

  it 'only registers tables that carry the two state columns' do
    described_class.entries.each do |entry|
      expect(entry.model.column_names).to include('embeddings_creation_flag', 'embedding_creation_error'),
                                          entry.key.inspect
    end
  end

  # Every atom, once, through the database: a typo in a join or a project column would
  # otherwise only surface on the page that uses it.
  it 'composes into runnable SQL for every entry, opt-in and project path included' do
    organisation = create(:organisation)
    ActsAsTenant.with_tenant(organisation) do
      described_class.entries.each do |entry|
        scope = entry.model.all
        scope = scope.joins(entry.join) if entry.join
        scope = scope.joins(entry.project_join) if entry.project_join
        expect { scope.where(entry.opt_in).group(entry.project_column).count }.not_to raise_error, entry.key.inspect
        expect { Fragment.joins(entry.fragment_join).count }.not_to raise_error, entry.key.inspect
      end
    end
  end

  it 'resolves a key in either spelling and answers nil for an unknown one (fail-closed)' do
    expect(described_class.entry_for(:notes).model_name).to eq('Note')
    expect(described_class.entry_for('notes').model_name).to eq('Note')
    expect(described_class.entry_for(:documents)).to be_nil
  end

  it 'builds no relation at load time (both tenant contexts must stay possible)' do
    expect(described_class.entries).to all(be_a(described_class::Entry))
    expect(described_class.entries.map(&:opt_in)).to all(be_a(String))
  end
end
