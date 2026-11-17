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
    account = account_of(entry)
    [([organisation_id, :person, entry.person.id] if entry.person),
     ([organisation_id, :account, account] if account)].compact
  end

  # The account behind a directory entry: the member's, or the one the row of a
  # deactivated member still carries. nil for a contact.
  def self.account_of(entry)
    entry.user&.id || entry.person&.user_id
  end

  # Normalize while membership visibility still applies. After DELETE a formerly
  # hidden member's linked row becomes a visible contact, so resolving aliases then
  # would use a relationship the owner was never allowed to see.
  def self.prepare_release(organisation_id:, user_id:, rows:)
    row_owners = where(organisation_id: organisation_id, person_id: rows.select(:id)).select(:owner_id)
    where(organisation_id: organisation_id, user_id: user_id, owner_id: row_owners).order(:owner_id).pluck(:owner_id).filter_map do |owner_id|
      settled = quietly do
        PersonGroup.lock_for(owner_id)
        settle_for_owner(owner_id)
        true
      end
      owner_id unless settled
    end
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
  def self.follow_to_row(organisation_id:, user_id:, rows:, failed_owners: [])
    by_account = where(organisation_id: organisation_id, user_id: user_id).where.not(owner_id: failed_owners)
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
  # owners are taken in the order of their ids to avoid reversing that lock order.
  def self.give_way(owner_id, by_account, by_row)
    PersonGroup.lock_for(owner_id)
    line = by_account.find_by(owner_id: owner_id)
    kept = by_row.find_by(owner_id: owner_id)
    # An alias the owner cannot see must not join visible people on their behalf. Its
    # account line can still go: the row line already preserves that hidden address.
    line.delete if line && kept
  end

  # Call only under PersonGroup.lock_for(owner_id), in the write's transaction. Merge,
  # split and membership release must all act on the grouping the reader displayed.
  # aliases: of a caller that read the owner's directories already
  # (People::AcrossOrganisations#entry_aliases); without them they are read here, and
  # only when a line by account stands beside a line by row in one organisation.
  def self.settle_for_owner(owner_id, aliases: nil)
    User.uncached do
      stored = where(owner_id: owner_id).pluck(:id, :person_group_id, *KEY_COLUMNS)
      row_organisations = stored.filter_map { |_, _, organisation_id, person_id, _| organisation_id if person_id }.to_set
      return unless stored.any? { |_, _, organisation_id, _, user_id| user_id && row_organisations.include?(organisation_id) }

      aliases ||= begin
        viewer = User.find_by(id: owner_id)
        return unless viewer

        People::AcrossOrganisations.aliases_for(viewer: viewer)
      end
      ids = stored.to_h { |id, _group, *address| [key_of(*address), id] }
      settled_lines(stored.map { |_, *line| line }, aliases: aliases) do |removed, destination, moved|
        where(id: moved.map { |key| ids.fetch(key) }).update_all(person_group_id: destination, updated_at: Time.current) if moved.any?
        where(id: ids.fetch(removed)).delete_all
      end
    end
  end

  # A step in a savepoint of its own; what the database refuses (a unique index, a row that
  # went, a deadlock it broke, a statement or a lock it gave up waiting for) is undone alone
  # and noted without any personal data.
  #
  # A step also reads the directories of ANOTHER person, the owner of the lines
  # (.settle_for_owner), and whatever that read raises is not the leaving member's
  # business either. Outside production it is raised, as an actor raises what it did not
  # expect (config.x.actors.reraise_unexpected): a bug shows. In production it is undone
  # like a refusal and logged as an error, by its class alone (a message may quote a row).
  REFUSALS = [ActiveRecord::RecordNotUnique, ActiveRecord::InvalidForeignKey, ActiveRecord::TransactionRollbackError,
              ActiveRecord::QueryCanceled, ActiveRecord::LockWaitTimeout].freeze

  def self.quietly(&)
    transaction(requires_new: true, &)
  rescue *REFUSALS => e
    Rails.logger.warn("[PersonGroupEntry] a merge entry stays as it is: #{e.class}")
    nil
  rescue StandardError => e
    raise if Rails.application.config.x.actors.reraise_unexpected

    Rails.logger.error("[PersonGroupEntry] a merge entry stays as it is, unexpectedly: #{e.class}")
    nil
  end
  private_class_method :give_way, :quietly

  # Pure normalization shared by the read and membership release. A row wins over its
  # account alias wherever it stands in a group. Move only sources whose organisations
  # are free in the recipient; conflicting leftovers remain grouped in the donor.
  # Resolve ALL visible aliases in immutable key order before releasing any one member:
  # crossed row/account references otherwise choose a different winner by release order.
  # Keep invisible lines as occupancy, but aliases come only from authorised directories.
  # The optional block persists the same steps under an owner lock; reads only get copies.
  def self.settled_lines(lines, aliases:)
    remaining = lines.map(&:dup)
    by_key = remaining.index_by { |line| key_of(*line.drop(1)) }
    aliases.sort.each do |organisation_id, person_id, user_id|
      account_key = [organisation_id, :account, user_id]
      line = by_key[account_key]
      kept = by_key[[organisation_id, :person, person_id]]
      next unless line && kept

      taken = remaining.select { |other| other.first == kept.first }.map { |other| other[1] }.to_set
      moving = remaining.select { |other| other.first == line.first && !taken.include?(other[1]) }
      yield account_key, kept.first, moving.map { |other| key_of(*other.drop(1)) } if block_given?
      moving.each { |other| other[0] = kept.first }
      remaining.delete(line)
      by_key.delete(account_key)
    end
    remaining
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
