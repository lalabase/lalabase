# frozen_string_literal: true

require 'rails_helper'

# What: the rules the DATABASE holds for a merge of the people above the organisations.
# Why:  the two tables carry no tenant, and an entry stores its owner and its organisation
#       beside the ids they belong to. Foreign keys, a check and three unique indexes keep
#       those columns honest, whatever code writes them. Every example reaches the
#       database with a statement of its own (insert_all and update_all run no callback
#       and no validation), so a rule dropped from the migration turns it red.
RSpec.describe PersonGroupEntry, :ci_guard do
  let(:owner) { create(:user) }
  let(:other_owner) { create(:user) }
  let(:member) { create(:user) }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued GmbH') }
  let(:group) { create(:person_group, owner: owner) }
  let(:row) { ActsAsTenant.with_tenant(north) { create(:person, organisation: north) } }
  let(:southern_row) { ActsAsTenant.with_tenant(south) { create(:person, organisation: south) } }

  # A savepoint per statement: a refused statement ends its own, and the example goes on.
  def statement(&)
    described_class.transaction(requires_new: true, &)
  end

  def insert(**columns)
    row = { person_group_id: group.id, owner_id: owner.id, organisation_id: north.id, person_id: nil, user_id: nil }
    statement { described_class.insert_all!([row.merge(columns)]) }
  end

  describe '.settled_lines' do
    it 'settles into a one-line recipient before visibility filtering, without mutating the stored lines' do
      lines = [['donor', 'A', 'early', nil], ['donor', 'B', nil, 'user'], ['kept', 'B', 'row', nil]]
      original = lines.map(&:dup)

      result = described_class.settled_lines(lines, aliases: [%w[B row user]])

      expect(result).to contain_exactly(['kept', 'A', 'early', nil], ['kept', 'B', 'row', nil])
      expect(lines).to eq(original)
    end

    it 'keeps conflicting leftovers merged and counts invisible recipient lines as occupied organisations' do
      lines = [['donor', 'A', 'early', nil], ['donor', 'B', nil, 'user'], ['donor', 'C', 'C1', nil], ['donor', 'D', 'D1', nil],
               ['kept', 'B', 'row', nil], ['kept', 'C', 'hidden-C2', nil], ['kept', 'D', 'D2', nil]]

      result = described_class.settled_lines(lines, aliases: [%w[B row user]])

      expect(result.select { |line| line.first == 'donor' }).to contain_exactly(['donor', 'C', 'C1', nil], ['donor', 'D', 'D1', nil])
      expect(result.select { |line| line.first == 'kept' }).to contain_exactly(['kept', 'A', 'early', nil], ['kept', 'B', 'row', nil],
                                                                               ['kept', 'C', 'hidden-C2', nil], ['kept', 'D', 'D2', nil])
    end

    it 'uses immutable alias order for cycles, independently of pluck order, and is idempotent' do
      lines = [['one', 'A', 'row-A', nil], ['one', 'B', nil, 'user-B'], ['one', 'C', 'C1', nil],
               ['two', 'A', nil, 'user-A'], ['two', 'B', 'row-B', nil], ['two', 'C', 'C2', nil]]
      aliases = [%w[A row-A user-A], %w[B row-B user-B]]
      expected = [['two', 'A', 'row-A', nil], ['two', 'B', 'row-B', nil], ['two', 'C', 'C2', nil], ['one', 'C', 'C1', nil]]

      [lines, lines.reverse, lines.rotate(2)].each do |ordered|
        result = described_class.settled_lines(ordered, aliases: aliases.reverse)
        expect(result).to match_array(expected)
        expect(described_class.settled_lines(result, aliases: aliases)).to eq(result)
      end
    end
  end

  describe 'exactly one address' do
    it 'takes an entry that names a row, and one that names an account' do
      expect { insert(person_id: row.id) }.to change(described_class, :count).by(1)
      expect { insert(organisation_id: south.id, user_id: member.id) }.to change(described_class, :count).by(1)
    end

    it 'refuses an entry that names both' do
      expect { insert(person_id: row.id, user_id: member.id) }
        .to raise_error(ActiveRecord::StatementInvalid, /person_group_entries_one_address/)
    end

    it 'refuses an entry that names neither' do
      expect { insert }.to raise_error(ActiveRecord::StatementInvalid, /person_group_entries_one_address/)
    end
  end

  describe 'the columns stored beside the ids' do
    it 'refuses an entry whose owner is not the owner of its group' do
      expect { insert(owner_id: other_owner.id, person_id: row.id) }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it 'refuses an entry whose organisation is not the organisation of its row' do
      expect { insert(organisation_id: south.id, person_id: row.id) }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it 'refuses to move a stored entry to another owner or another organisation' do
      insert(person_id: row.id)
      entry = described_class.sole

      expect { statement { described_class.where(id: entry.id).update_all(owner_id: other_owner.id) } }
        .to raise_error(ActiveRecord::InvalidForeignKey)
      expect { statement { described_class.where(id: entry.id).update_all(organisation_id: south.id) } }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe 'one entry per owner and address, one source per organisation' do
    let(:second_group) { create(:person_group, owner: owner) }

    it 'refuses a second entry of one owner for the same row' do
      insert(person_id: row.id)

      expect { insert(person_group_id: second_group.id, person_id: row.id) }
        .to raise_error(ActiveRecord::RecordNotUnique, /index_person_group_entries_on_owner_and_person/)
    end

    it 'refuses a second entry of one owner for the same member in the same organisation' do
      insert(user_id: member.id)

      expect { insert(person_group_id: second_group.id, user_id: member.id) }
        .to raise_error(ActiveRecord::RecordNotUnique, /index_person_group_entries_on_owner_and_account/)
    end

    it 'takes the same member in another organisation, and the same row for another owner' do
      insert(user_id: member.id)
      insert(person_group_id: second_group.id, person_id: row.id)
      foreign_group = create(:person_group, owner: other_owner)

      expect { insert(person_group_id: second_group.id, organisation_id: south.id, user_id: member.id) }
        .to change(described_class, :count).by(1)
      expect { insert(person_group_id: foreign_group.id, owner_id: other_owner.id, person_id: row.id) }
        .to change(described_class, :count).by(1)
    end

    it 'refuses a second entry of one group in the same organisation' do
      second_row = ActsAsTenant.with_tenant(north) { create(:person, organisation: north) }
      insert(person_id: row.id)

      expect { insert(person_id: second_row.id) }
        .to raise_error(ActiveRecord::RecordNotUnique, /index_person_group_entries_on_group_and_organisation/)
      expect { insert(user_id: member.id) }
        .to raise_error(ActiveRecord::RecordNotUnique, /index_person_group_entries_on_group_and_organisation/)
    end
  end

  describe 'what takes an entry along' do
    before do
      insert(person_id: row.id)
      insert(organisation_id: south.id, person_id: southern_row.id)
    end

    it 'deletes the entry with its row, and leaves the other entry and the group' do
      expect { Person.unscoped.where(id: row.id).delete_all }.to change(described_class, :count).from(2).to(1)

      expect(described_class.sole.person_id).to eq(southern_row.id)
      expect(PersonGroup.where(id: group.id)).to exist
    end

    it 'deletes the entries with their group' do
      expect { PersonGroup.where(id: group.id).delete_all }.to change(described_class, :count).from(2).to(0)
    end

    it 'deletes the entry of a member without a row with its organisation' do
      empty = create(:organisation)
      insert(organisation_id: empty.id, user_id: member.id)

      expect { Organisation.where(id: empty.id).delete_all }.to change(described_class, :count).from(3).to(2)
    end
  end

  describe 'the indexes and keys as the database names them' do
    it 'holds the unique index on people (id, organisation_id) the composite key points at' do
      index = described_class.connection.indexes(:people).find { |candidate| candidate.columns == %w[id organisation_id] }

      expect(index&.unique).to be(true)
    end

    # Every read of the list, every merge, split and release asks for the lines of ONE
    # owner. The two unique indexes begin with the owner, but each holds the lines of one
    # kind of address only (a partial index), and a query that does not repeat that
    # condition cannot use either: without this index it reads the lines of everybody.
    it 'holds an index that serves "the lines of one owner"' do
      serving = described_class.connection.indexes(:person_group_entries)
                               .select { |index| Array(index.columns).first == 'owner_id' && index.where.nil? }

      expect(serving.map(&:name)).to eq(['index_person_group_entries_on_owner_id'])
    end

    it 'holds both composite foreign keys with ON DELETE CASCADE' do
      keys = described_class.connection.foreign_keys(:person_group_entries)
                            .to_h { |key| [key.to_table, [Array(key.column), Array(key.primary_key), key.on_delete]] }

      expect(keys['person_groups']).to eq([%w[person_group_id owner_id], %w[id owner_id], :cascade])
      expect(keys['people']).to eq([%w[person_id organisation_id], %w[id organisation_id], :cascade])
      expect(keys['organisations']).to eq([%w[organisation_id], %w[id], :cascade])
      expect(keys['users'].first).to eq(%w[user_id])
    end
  end

  describe 'the models' do
    # A model with a tenant raises when it is read without one (require_tenant).
    it 'carry no tenant: a group reaches over organisations' do
      insert(person_id: row.id)

      expect(ActsAsTenant.current_tenant).to be_nil
      expect([described_class, PersonGroup].map { |model| model.respond_to?(:scoped_by_tenant?) && model.scoped_by_tenant? })
        .to eq([false, false])
      expect { [described_class.count, PersonGroup.count] }.not_to raise_error
      expect { Person.count }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
    end

    # Person carries a tenant and raises when it is loaded outside one. An entry is held by
    # id against the directory of its organisation, never loaded through the model.
    it 'declare no association to Person' do
      [described_class, PersonGroup].each do |model|
        targets = model.reflect_on_all_associations.map(&:class_name)

        expect(targets).not_to include('Person'), "#{model} reaches Person through an association"
      end
      expect(described_class.reflect_on_all_associations.map(&:name)).to contain_exactly(:person_group, :owner, :organisation, :user)
    end
  end

  describe 'holding a stored entry against an entry of a directory' do
    def directory_entry(person: nil, user: nil)
      People::Directory::Entry.new(kind: user ? :member : :contact, user: user, person: person, sort_name: 'x')
    end

    it 'stores the row whenever there is one, and the account only for a member without a row' do
      linked = ActsAsTenant.with_tenant(north) { build_stubbed(:person, organisation: north, user_id: member.id) }

      expect(described_class.address_of(directory_entry(person: row))).to eq(person_id: row.id, user_id: nil)
      expect(described_class.address_of(directory_entry(person: linked, user: member))).to eq(person_id: linked.id, user_id: nil)
      expect(described_class.address_of(directory_entry(user: member))).to eq(person_id: nil, user_id: member.id)
    end

    it 'names a directory entry by its row, and by the account behind it' do
      insert(user_id: member.id)
      insert(organisation_id: south.id, person_id: southern_row.id)
      by_account = described_class.find_by!(user_id: member.id)
      by_row = described_class.find_by!(person_id: southern_row.id)
      linked = ActsAsTenant.with_tenant(north) { build_stubbed(:person, organisation: north, user_id: member.id) }
      names = ->(line, organisation, entry) { described_class.keys_for(organisation.id, entry).include?(line.key) }

      # A member without a row, the same member with a row, and the row of that member once
      # deactivated (a contact whose row still carries the account).
      expect(names.call(by_account, north, directory_entry(user: member))).to be(true)
      expect(names.call(by_account, north, directory_entry(person: linked, user: member))).to be(true)
      expect(names.call(by_account, north, directory_entry(person: linked))).to be(true)
      expect(names.call(by_row, south, directory_entry(person: southern_row))).to be(true)
      # Not the same account in another organisation, not an unlinked row, not another row.
      expect(names.call(by_account, south, directory_entry(user: member))).to be(false)
      expect(names.call(by_account, north, directory_entry(person: row))).to be(false)
      expect(names.call(by_row, south, directory_entry(person: row))).to be(false)
    end
  end
end
