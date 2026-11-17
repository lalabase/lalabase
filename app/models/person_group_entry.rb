# frozen_string_literal: true

# One source of a merge (PersonGroup): a row of one organisation's people directory, or
# a member of it who has no row.
#
# * Exactly one address, and the row wins: person_id whenever the member or contact has
#   a row when the merge is written, user_id only for a member without one (a check
#   constraint holds "exactly one"). When that member leaves the organisation, the
#   entry is rewritten to their row (PersonLinkRelease).
# * NEVER resolved through an association: there is no belongs_to :person. Person carries
#   a tenant, and loading one outside it raises. An entry is held by id against the
#   entries of an organisation's directory (.keys_for, #key), which the owner read under
#   that tenant with their own right there. A reference is not a right: an entry the
#   directory does not return is not shown.
# * No tenant of its own, although it stores organisation_id: the owner's groups reach
#   over organisations. The foreign keys keep the column honest (the organisation of an
#   entry is the organisation of its row) and take the entry along with a deleted row,
#   organisation or group.
class PersonGroupEntry < ApplicationRecord
  belongs_to :person_group, inverse_of: :entries
  belongs_to :owner, class_name: 'User'
  belongs_to :organisation
  belongs_to :user, optional: true

  scope :owned_by, ->(user) { where(owner_id: user.id) }

  # How an entry of a directory (People::Directory::Entry) is stored: its row when it has
  # one, else the account of the member.
  def self.address_of(entry)
    entry.person ? { person_id: entry.person.id, user_id: nil } : { person_id: nil, user_id: entry.user.id }
  end

  # The keys a directory entry of this organisation answers to: its row, and the account
  # behind it (the member's, or the one a deactivated member's row still carries). A
  # stored entry names the directory entry when its #key is one of them.
  def self.keys_for(organisation_id, entry)
    account = entry.user&.id || entry.person&.user_id
    [([organisation_id, :person, entry.person.id] if entry.person),
     ([organisation_id, :account, account] if account)].compact
  end

  # A member leaves the organisation and their row loses its link to the account
  # (PersonLinkRelease): the entries that named them by account name the row from now on,
  # for every owner. rows: the relation of that row (at most one: an account has one row
  # per organisation), named by the caller while the row still carries the account.
  # Without a row nothing changes. No row is loaded.
  #
  # An owner who holds an entry for that row already keeps that one (the unique index would
  # refuse a second). Their entry by account gives way first (.give_way): what it was
  # merged with moves over to the group of the row, so the person stays whole. Every other
  # entry by account is rewritten in one statement.
  #
  # ⚠️ This runs inside the removal of a membership, also when an account is erased.
  # Somebody's private note must never stop a member from leaving: each step stands in a
  # savepoint of its own, and a step the database refuses is undone alone (.quietly). The
  # lines it concerned then stay as they are; they name the account, which no longer leads
  # to the row, until that member comes back.
  def self.follow_to_row(organisation_id:, user_id:, rows:)
    by_account = where(organisation_id: organisation_id, user_id: user_id)
    by_row = where(organisation_id: organisation_id, person_id: rows.select(:id))
    by_account.where(owner_id: by_row.select(:owner_id)).order(:owner_id).pluck(:owner_id).each do |owner_id|
      quietly { give_way(owner_id, by_account, by_row) }
    end
    quietly do
      by_account.where(rows.arel.exists).where.not(owner_id: by_row.select(:owner_id))
                .update_all(person_id: Arel::Nodes::Grouping.new(rows.select(:id).arel), user_id: nil, updated_at: Time.current)
    end
  end

  # One owner who names the leaving member twice, by account and by row. Under the lock a
  # merge or a split of that owner takes (PersonGroup.lock_for), and only then read: a
  # merge of theirs that is being written is waited for, and what it stored is seen. The
  # owners are taken in the order of their ids, so two removals never wait for each other.
  def self.give_way(owner_id, by_account, by_row)
    PersonGroup.lock_for(owner_id)
    line = by_account.find_by(owner_id: owner_id)
    kept = by_row.find_by(owner_id: owner_id)
    line.give_way_to(kept) if line && kept
  end

  # A step in a savepoint of its own; what the database refuses (a unique index, a row that
  # went, a deadlock it broke) is undone alone and noted without any personal data.
  def self.quietly(&)
    transaction(requires_new: true, &)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::InvalidForeignKey, ActiveRecord::Deadlocked => e
    Rails.logger.warn("[PersonGroupEntry] a merge entry stays as it is: #{e.class}")
    nil
  end
  private_class_method :give_way, :quietly

  # This line and `kept` name the same human for one owner, in two groups. The other
  # entries of this line's group move to the group of `kept`, each unless that group holds
  # a source of its organisation already (one source per organisation; such an entry stays
  # where it is). Then this line goes. A group left with fewer than two entries is ignored
  # by the read and deleted by the next merge or split of its owner.
  def give_way_to(kept)
    taken = self.class.where(person_group_id: kept.person_group_id).select(:organisation_id)
    self.class.where(person_group_id: person_group_id).where.not(id: id).where.not(organisation_id: taken)
        .update_all(person_group_id: kept.person_group_id, updated_at: Time.current)
    delete
  end

  # The columns a key is made of, for a read that plucks them instead of loading entries.
  KEY_COLUMNS = %i[organisation_id person_id user_id].freeze

  def self.key_of(organisation_id, person_id, user_id)
    person_id ? [organisation_id, :person, person_id] : [organisation_id, :account, user_id]
  end

  def key
    self.class.key_of(organisation_id, person_id, user_id)
  end
end
