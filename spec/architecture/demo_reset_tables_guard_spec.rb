# frozen_string_literal: true

require 'rails_helper'

# Which tables the demo reset (Lalabase::Demo::Reset) keeps. Everything else is wiped,
# so a new table of visitor content needs no entry; a kept table is the exception and
# has to stay one that holds nothing a visitor wrote.
RSpec.describe 'Demo reset tables', :ci_guard, type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:kept) { connection.tables.select { |table| Lalabase::Demo::Reset.kept_table?(table) } }
  let(:wiped) { Lalabase::Demo::Reset.wiped_tables(connection) }

  it 'keeps only tables that exist' do
    expect(Lalabase::Demo::Reset::KEPT_TABLES - connection.tables).to be_empty
  end

  # TRUNCATE without CASCADE refuses such a pair; with CASCADE it would empty the kept
  # table. Either way the reset could not keep it.
  it 'keeps no table that references a wiped one' do
    references = kept.flat_map do |table|
      connection.foreign_keys(table).filter_map { |fk| "#{table} -> #{fk.to_table}" if wiped.include?(fk.to_table) }
    end
    expect(references).to be_empty
  end

  # A row that names an organisation or a person belongs to the world of one day.
  it 'keeps no table with rows of an organisation or a person' do
    owned = kept.select { |table| connection.columns(table).map(&:name).intersect?(%w[organisation_id user_id]) }
    expect(owned).to be_empty
  end

  # Files of kept records are copied across the reset (Reset::StoredFiles); rich text
  # is not, its table is wiped, and a kept record would come back without its text.
  it 'keeps no record with rich text' do
    Rails.application.eager_load!
    with_rich_text = ApplicationRecord.descendants.reject(&:abstract_class?).select do |model|
      model.reflect_on_all_associations.any? { |association| association.class_name == 'ActionText::RichText' }
    end
    # The scan has to see rich text at all, or an empty answer below proves nothing.
    expect(with_rich_text).to include(Ticket)
    expect(with_rich_text.select { |model| Lalabase::Demo::Reset.kept_table?(model.table_name) }).to be_empty
  end

  it 'wipes the tables of the world' do
    expect(wiped).to include('organisations', 'users', 'tickets', 'active_storage_blobs', 'prompt_personas')
  end
end
