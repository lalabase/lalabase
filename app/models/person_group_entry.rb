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
  # per organisation), named by the caller while the row still carries the account. An
  # owner who holds an entry for that row already keeps that one; their entry by account
  # goes first, the unique index would refuse the rewrite. Without a row nothing changes.
  # Two statements, no row is loaded.
  def self.follow_to_row(organisation_id:, user_id:, rows:)
    by_account = where(organisation_id: organisation_id, user_id: user_id)
    row_id = rows.select(:id)
    by_account.where(owner_id: where(organisation_id: organisation_id, person_id: row_id).select(:owner_id)).delete_all
    by_account.where(rows.arel.exists)
              .update_all(person_id: Arel::Nodes::Grouping.new(row_id.arel), user_id: nil, updated_at: Time.current)
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
