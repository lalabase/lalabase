# frozen_string_literal: true

# app/services/actors/merge_people.rb
#
# Merges entries of the people directories of DIFFERENT organisations into one person,
# for the viewer alone (the people above the organisations, GET /people). A merge is the
# viewer's private note: two rows in two tables without a tenant (PersonGroup,
# PersonGroupEntry). Nothing in an organisation changes, nothing is tracked, and no
# organisation learns of it.
#
# entries: a list of { org:, id: }, the organisation's id and the address of the entry in
# its directory ("person:<uuid>" or "member:<uuid>", People::Lookup). Nothing of it is
# trusted:
#
# * an organisation comes from the viewer's ACTIVE memberships, never from the id as sent;
# * every entry is read again inside ActsAsTenant.with_tenant(organisation), through
#   People::Lookup#entry, with the viewer's own right to read that directory. An unknown
#   entry, one of another organisation, one the viewer may not see, a malformed id, an
#   organisation that is not the viewer's or does not exist: ONE refusal (:not_found, the
#   text of an unknown person). A caller cannot tell them apart;
# * the tenant is lifted nowhere.
#
# What is stored: the row (person_id) whenever the entry has one, the account (user_id)
# only for a member without a row (PersonGroupEntry.address_of). An entry that is stored
# already keeps its line; its group is joined.
#
# * Two entries of one organisation are refused with a text of their own, on the ids as
#   they were sent (before anything is read, so the answer says nothing about an entry).
#   Two rows of one organisation that are the same human are that organisation's
#   business. The same refusal when joining groups would put two entries of one
#   organisation into one group.
# * Entries that are each in a group: the entries move into the oldest group, the others
#   are deleted.
# * Members with the same account are one person already (computed by the read, stored
#   nowhere). A merge of nothing but such entries writes nothing.
# * One merge at a time per owner (PersonGroup.lock_for, held until the transaction
#   ends): a second one reads what the first one wrote. A unique index or a foreign key
#   that still refuses (a row deleted meanwhile, a member leaving) is a failure with a
#   message (:conflict), never an exception.
# * The owner's groups left with fewer than two entries are deleted on the way.
module Actors
  class MergePeople < BaseActor
    NOT_FOUND = :not_found
    TOO_FEW = :too_few
    SAME_ORGANISATION = :same_organisation
    CONFLICT = :conflict

    # One entry as the directory returned it: where it is, how it is stored, the account
    # of a member (what makes two members one person), and the keys a stored entry names
    # it by (PersonGroupEntry.keys_for).
    Chosen = Struct.new(:organisation_id, :address, :account, :keys)
    private_constant :Chosen

    def initialize(entries:, current_user:, account_lock_ids: nil)
      super()
      @entries = wanted(entries)
      @current_user = current_user
      @account_lock_ids = account_lock_ids
    end

    # The group the entries are in afterwards; nil when nothing had to be stored.
    def record
      @group
    end

    def perform
      refuse(TOO_FEW, 'too_few') if @entries.size < 2
      refuse(SAME_ORGANISATION, 'same_organisation') if repeated?(@entries.filter_map(&:first))

      chosen = read_entries
      locked_accounts = lock_accounts(chosen)
      PersonGroup.lock_for(current_user)
      # Either wait may have changed access or the account a row resolves to. Use fresh
      # queries AND a fresh viewer (policies cache memberships on that instance).
      User.uncached do
        refuse(CONFLICT, 'conflict') unless User.where(id: locked_accounts).count == locked_accounts.size
        @current_user = User.find(current_user.id)
        chosen = read_entries
        refuse(CONFLICT, 'conflict') unless (accounts_of(chosen) - locked_accounts).empty?
        PersonGroupEntry.settle_for_owner(current_user.id)
        join(chosen)
      end
      sweep
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::InvalidForeignKey
      refuse(CONFLICT, 'conflict')
    end

    private

    attr_reader :current_user

    # Shared locks allow concurrent merges; erasure takes their exclusive counterpart
    # before any cleanup (PersonalDataErasure). Take every account lock BEFORE
    # the owner advisory lock: erasure also removes memberships whose callbacks need
    # owner locks. Reversing those two levels would deadlock.
    def lock_accounts(chosen)
      ids = accounts_of(chosen)
      # A takeover already wrote its copy under the owner's lock. It may not expand
      # its lock set here if the source acquired an account in the meantime.
      refuse(CONFLICT, 'conflict') if @account_lock_ids && (ids - @account_lock_ids).any?
      PersonalDataErasure.lock_accounts(ids, shared: true)
      ids
    end

    def accounts_of(chosen)
      ([current_user.id] + chosen.flat_map { |entry| entry.keys.filter_map { |_, kind, id| id if kind == :account } }).uniq.sort
    end

    # Pairs of [organisation id, address], each once. Anything of another shape stays in
    # the list as a pair that names nothing, so it is refused like an unknown entry
    # instead of being dropped without a word.
    def wanted(entries)
      return [] unless entries.is_a?(Array)

      entries.map { |entry| pair(entry) }.uniq
    end

    def pair(entry)
      organisation_id, id = entry.values_at(:org, :id) if entry.is_a?(Hash)
      [(Lalabase::Uuid.dashed(organisation_id) if organisation_id.is_a?(String)), (id if id.is_a?(String))]
    end

    def repeated?(values)
      values.uniq.size < values.size
    end

    # Every entry as the viewer may read it in its organisation, or the one refusal. The
    # organisations are the viewer's ACTIVE memberships among the ids sent, read once; an
    # organisation stands in the list once, so each directory is read once.
    def read_entries
      organisations = current_user.active_organisations.where(id: @entries.filter_map(&:first)).index_by(&:id)
      @entries.map do |organisation_id, id|
        organisation = organisations[organisation_id]
        refuse_unknown unless organisation && id

        in_people_organisation(organisation) { chosen_in(organisation, id) }
      end
    end

    def chosen_in(organisation, id)
      entry = People::Lookup.new(viewer: current_user, organisation: organisation).entry(id)
      refuse_unknown unless entry

      chosen_entry(organisation, entry)
    rescue People::Lookup::Refused, People::Lookup::InvalidArgument
      refuse_unknown
    end

    # Named like the loop of the list (People::AcrossOrganisations): one frame per
    # organisation in the Prosopite stack, bounded by the viewer's organisations.
    def in_people_organisation(organisation, &)
      ActsAsTenant.with_tenant(organisation, &)
    end

    def chosen_entry(organisation, entry)
      Chosen.new(organisation.id, PersonGroupEntry.address_of(entry), (entry.user.id if entry.member?),
                 PersonGroupEntry.keys_for(organisation.id, entry))
    end

    def join(chosen)
      stored = stored_for(chosen)
      # Before the lines by account go: their groups are part of this merge too, or what
      # they hold would fall out of the person without a word.
      groups = groups_of(stored.values.flatten)
      stored = settled(stored)
      added = chosen.select { |entry| stored[entry].empty? }
      return if groups.empty? && same_account?(chosen)

      one_source_per_organisation!(groups, added)
      @group = groups.first || PersonGroup.create!(owner: current_user)
      absorb(groups.drop(1))
      add(added)
    end

    # The owner's stored entries that name a chosen entry already, per chosen entry: read
    # once for the organisations of the merge and held against the keys.
    def stored_for(chosen)
      lines = PersonGroupEntry.owned_by(current_user).where(organisation_id: chosen.map(&:organisation_id)).to_a
      chosen.each_with_object({}.compare_by_identity) do |entry, found|
        found[entry] = lines.select { |line| entry.keys.include?(line.key) }
      end
    end

    # One line per chosen entry. A row that was linked to a member AFTER two merges were
    # written can be named twice by one owner, by the row in one group and by the account
    # in another; the read shows both groups as one person. The line by account goes, the
    # row wins. Both groups were counted in before (#join), so they are joined like any
    # others, or the merge is refused when they cannot be one.
    def settled(stored)
      twice = stored.values.select { |lines| lines.size > 1 }
      return stored if twice.empty?

      PersonGroupEntry.where(id: twice.flatten.select(&:user_id).map(&:id)).delete_all
      stored.transform_values { |lines| lines.size > 1 ? lines.reject(&:user_id) : lines }.compare_by_identity
    end

    # The owner's groups those entries are in, the oldest first.
    def groups_of(lines)
      PersonGroup.owned_by(current_user).where(id: lines.map(&:person_group_id).uniq).order(:created_at, :id).to_a
    end

    # Nothing but members with one account: the read shows them as one person already.
    def same_account?(chosen)
      accounts = chosen.map(&:account)
      accounts.none?(&:nil?) && accounts.uniq.one?
    end

    # What the joined group would hold: the stored entries of every group it is made of,
    # also those the viewer cannot see just now (they are the viewer's own notes), and
    # the entries added.
    def one_source_per_organisation!(groups, added)
      stored = PersonGroupEntry.where(person_group_id: groups.map(&:id)).pluck(*PersonGroupEntry::KEY_COLUMNS)
      refuse_overlap! if repeated?(stored.map(&:first) + added.map(&:organisation_id))

      # A member brings every visible membership of their account into the displayed
      # person, even when the dialog submitted only one of them. Resolve the stored
      # notes through the same directories too: a linked row may now name a member.
      sources = stored.map { |values| PersonGroupEntry.key_of(*values) } + added.map { |entry| entry.keys.first }
      visible = visible_entries
      by_key = visible.flat_map { |entry| entry.keys.map { |key| [key, entry] } }.to_h
      accounts = sources.filter_map { |key| by_key[key]&.account }.to_set
      expanded = visible.select { |entry| entry.account && accounts.include?(entry.account) }.map { |entry| entry.keys.first }
      canonical = sources.map { |key| by_key[key]&.keys&.first || key }
      refuse_overlap! if repeated?((canonical + expanded).uniq.map(&:first))
    end

    # Only sources the viewer can actually read contribute account-derived entries;
    # a raw query across memberships would expose hidden members through a refusal.
    def visible_entries
      current_user.active_organisations.by_name.flat_map do |organisation|
        in_people_organisation(organisation) do
          lookup = People::Lookup.new(viewer: current_user, organisation: organisation)
          lookup.allowed? ? lookup.listing.entries.map { |entry| chosen_entry(organisation, entry) } : []
        end
      end
    end

    def refuse_overlap!
      refuse(SAME_ORGANISATION, 'same_organisation')
    end

    def absorb(groups)
      return if groups.empty?

      ids = groups.map(&:id)
      PersonGroupEntry.where(person_group_id: ids).update_all(person_group_id: @group.id, updated_at: Time.current)
      PersonGroup.where(id: ids).delete_all
    end

    # One statement for all of them. No validation runs: the check, the foreign keys and
    # the unique indexes of the table hold every rule of an entry.
    def add(added)
      return if added.empty?

      PersonGroupEntry.insert_all!(added.map do |entry|
        { person_group_id: @group.id, owner_id: current_user.id, organisation_id: entry.organisation_id, **entry.address }
      end)
    end

    # Groups a deleted row, organisation or entry left with fewer than two entries. Counted
    # on what is stored, not on what the viewer sees: a group whose other part is hidden
    # for want of a right stays.
    def sweep
      PersonGroup.owned_by(current_user).leftover.delete_all
    end

    def refuse_unknown
      raise ActorError.new(I18n.t('controllers.people.not_found'), code: NOT_FOUND)
    end

    def refuse(code, key)
      raise ActorError.new(I18n.t("controllers.people.merge.#{key}"), code: code)
    end
  end
end
