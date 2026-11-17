# frozen_string_literal: true

# app/services/actors/merge_people.rb
#
# Merges entries of the people directories of DIFFERENT organisations into one person,
# for the viewer alone (the people above the organisations, GET /people). A merge is the
# viewer's private note: two rows in two tables without a tenant (PersonGroup,
# PersonGroupEntry). Nothing in an organisation changes, nothing is tracked, and no
# organisation learns of it.
#
# entries: the rows to join. A row is a source { org:, id: }, the organisation's id and the
# address of the entry in its directory ("person:<uuid>" or "member:<uuid>",
# People::Lookup), or a list of sources: a row of the list that stands for several
# organisations already (one account, an earlier merge) is sent with all of them. Fewer
# than two ROWS are refused, however many sources one row has: a single row joins
# nothing. Nothing of it is trusted:
#
# * an organisation comes from the viewer's ACTIVE memberships, never from the id as sent;
# * every entry is read again inside ActsAsTenant.with_tenant(organisation), through
#   People::Lookup, with the viewer's own right to read that directory. An unknown entry,
#   one of another organisation, one the viewer may not see, a malformed id, an
#   organisation that is not the viewer's or does not exist: ONE refusal (:not_found, the
#   text of an unknown person). A caller cannot tell them apart;
# * the tenant is lifted nowhere.
#
# The merge acts on the PEOPLE THE LIST SHOWS (People::AcrossOrganisations), not on the
# lines as they are stored: every chosen entry stands for the whole row it is shown in
# (the other organisations of its account, what earlier merges joined), and those rows
# become one.
#
# * Two entries of one organisation are refused with a text of their own, on the ids as
#   they were sent (before anything is read, so the answer says nothing about an entry),
#   and again when the rows to join show two sources of one organisation. Two rows of one
#   organisation that are the same human are that organisation's business.
# * What is stored: the row (person_id) whenever a chosen entry has one, the account
#   (user_id) only for a member without a row (PersonGroupEntry.address_of). An entry that
#   is stored already keeps its line.
# * One group per shown person: the lines that name it move into the oldest of their
#   groups that can hold it (#home_for), else into a new one. Rows the list shows as one
#   already get nothing new, and two groups that join one row become one.
# * A stored line the list does NOT show as part of that person never refuses the merge.
#   It stays in its group, and a group left with fewer than two lines goes (#sweep): a
#   line whose member left without a row, a line of a row the account rule shows
#   elsewhere. A line of a part that is hidden just now (no right there any more) follows
#   the person while its organisation is free.
# * One merge at a time per owner (PersonGroup.lock_for, held until the transaction
#   ends): a second one reads what the first one wrote. A unique index or a foreign key
#   that still refuses (a row deleted meanwhile, a member leaving) is a failure with a
#   message (:conflict), never an exception.
# * Two reads: the chosen entries before the locks, for the accounts to lock, then every
#   directory of the viewer ONCE under the locks (one People::AcrossOrganisations), from
#   which the entries, the aliases to settle and the shown people all come.
module Actors
  class MergePeople < BaseActor
    NOT_FOUND = :not_found
    TOO_FEW = :too_few
    SAME_ORGANISATION = :same_organisation
    CONFLICT = :conflict
    # The codes whose text is written for the viewer. Any other failure carries a message
    # nobody wrote for a page (BaseActor#handle_unexpected_error passes the exception's).
    REFUSALS = [NOT_FOUND, TOO_FEW, SAME_ORGANISATION, CONFLICT].freeze

    # A stored entry of the owner while the merge is written.
    Line = Struct.new(:id, :group_id, :organisation_id, :key)
    private_constant :Line

    def initialize(entries:, current_user:, account_lock_ids: nil)
      super()
      @rows = wanted(entries)
      @entries = @rows.flatten(1).uniq
      @current_user = current_user
      @account_lock_ids = account_lock_ids
    end

    # The group the entries are in afterwards; nil when nothing had to be stored.
    def record
      @group
    end

    def perform
      refuse(TOO_FEW, 'too_few') if @rows.size < 2
      refuse(SAME_ORGANISATION, 'same_organisation') if repeated?(@entries.filter_map(&:first))

      locked_accounts = lock_accounts(accounts_named)
      PersonGroup.lock_for(current_user)
      # Either wait may have changed access or the account a row resolves to. Use fresh
      # queries AND a fresh viewer (policies cache memberships on that instance).
      User.uncached do
        refuse(CONFLICT, 'conflict') unless User.where(id: locked_accounts).count == locked_accounts.size
        @current_user = User.find(current_user.id)
        shown = People::AcrossOrganisations.new(viewer: current_user)
        chosen = @entries.map { |organisation_id, id| shown.part(organisation_id, id) || refuse_unknown }
        refuse(CONFLICT, 'conflict') unless (accounts_of(chosen.map(&:account)) - locked_accounts).empty?
        PersonGroupEntry.settle_for_owner(current_user.id, aliases: shown.entry_aliases)
        join(shown, chosen)
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
    def lock_accounts(named)
      ids = accounts_of(named)
      # A takeover already wrote its copy under the owner's lock. It may not expand
      # its lock set here if the source acquired an account in the meantime.
      refuse(CONFLICT, 'conflict') if @account_lock_ids && (ids - @account_lock_ids).any?
      PersonalDataErasure.lock_accounts(ids, shared: true)
      ids
    end

    # The owner and the accounts behind the chosen entries (nil: a contact).
    def accounts_of(named)
      ([current_user.id] + named.compact).uniq.sort
    end

    # The rows as sent, each once: a row is its pairs of [organisation id, address]. A
    # source of another shape stays in its row as a pair that names nothing, so it is
    # refused like an unknown entry instead of being dropped without a word. A row
    # without any source is no row.
    def wanted(entries)
      return [] unless entries.is_a?(Array)

      entries.map { |row| (row.is_a?(Array) ? row : [row]).map { |source| pair(source) }.uniq }.reject(&:empty?).uniq
    end

    def pair(entry)
      organisation_id, id = entry.values_at(:org, :id) if entry.is_a?(Hash)
      [(Lalabase::Uuid.dashed(organisation_id) if organisation_id.is_a?(String)), (id if id.is_a?(String))]
    end

    def repeated?(values)
      values.uniq.size < values.size
    end

    # Before the locks, and only to know which accounts to lock: the account behind every
    # chosen entry as the viewer may read it in its organisation, or the one refusal. The
    # organisations are the viewer's ACTIVE memberships among the ids sent, read once; an
    # organisation stands in the list once, so each of these directories is read once.
    def accounts_named
      organisations = current_user.active_organisations.where(id: @entries.filter_map(&:first)).index_by(&:id)
      @entries.map do |organisation_id, id|
        organisation = organisations[organisation_id]
        refuse_unknown unless organisation && id

        in_people_organisation(organisation) { account_in(organisation, id) }
      end
    end

    def account_in(organisation, id)
      entry = People::Lookup.new(viewer: current_user, organisation: organisation).listing.entry(id)
      refuse_unknown unless entry

      PersonGroupEntry.account_of(entry)
    rescue People::Lookup::Refused, People::Lookup::InvalidArgument
      refuse_unknown
    end

    # Named like the loop of the list (People::AcrossOrganisations): one frame per
    # organisation in the Prosopite stack, bounded by the viewer's organisations.
    def in_people_organisation(organisation, &)
      ActsAsTenant.with_tenant(organisation, &)
    end

    # The rows the list shows the chosen entries in become one person. Rows that are one
    # already (one account, or one merge) get nothing new.
    def join(shown, chosen)
      people = chosen.map { |part| shown.person_with(part) }.uniq(&:object_id)
      members = people.flatten
      refuse(SAME_ORGANISATION, 'same_organisation') if repeated?(members.map(&:organisation_id))

      lines = stored_lines
      held = lines.values_at(*members.flat_map(&:keys)).compact.uniq
      groups = groups_of(held)
      return @group = groups.first if people.one? && groups.size < 2

      others = lines.values.select { |line| groups.any? { |group| group.id == line.group_id } } - held
      @group = home_for(shown, members, groups, others) || PersonGroup.create!(owner: current_user)
      gather(held + following(shown, members, groups, others))
      add(chosen.reject { |part| lines.values_at(*part.keys).any? })
    end

    # The owner's stored entries by their key, read once under the owner's lock.
    def stored_lines
      PersonGroupEntry.owned_by(current_user).pluck(:id, :person_group_id, *PersonGroupEntry::KEY_COLUMNS)
                      .to_h do |id, group_id, *address|
        key = PersonGroupEntry.key_of(*address)
        [key, Line.new(id, group_id, address.first, key)]
      end
    end

    # The owner's groups those lines are in, the oldest first.
    def groups_of(lines)
      PersonGroup.owned_by(current_user).where(id: lines.map(&:group_id).uniq).order(:created_at, :id).to_a
    end

    # The oldest of the groups that can hold the person as the list will show it: none of
    # its other lines names an entry the list shows (that entry stands in another row, and
    # a group that named both would pull the new sources over to it), and none sits in an
    # organisation the person has a source of (one source per organisation). nil: a new
    # group, and such lines stay behind in theirs.
    def home_for(shown, members, groups, others)
      needed = members.to_set(&:organisation_id)
      groups.find do |group|
        others.none? { |line| line.group_id == group.id && (needed.include?(line.organisation_id) || shown.names?(line.key)) }
      end
    end

    # The other lines of those groups that name nothing the viewer sees just now: the
    # viewer's own notes about a part that is hidden (no right there any more). They follow
    # the person while their organisation is free in its group, the oldest group first.
    def following(shown, members, groups, others)
      hidden = others.reject { |line| shown.names?(line.key) }
      taken = members.to_set(&:organisation_id)
      hidden.each { |line| taken << line.organisation_id if line.group_id == @group.id }
      age = groups.each_with_index.to_h { |group, index| [group.id, index] }
      hidden.reject { |line| line.group_id == @group.id }.sort_by { |line| [age.fetch(line.group_id), line.id] }
            .select { |line| taken.add?(line.organisation_id) }
    end

    def gather(lines)
      ids = lines.reject { |line| line.group_id == @group.id }.map(&:id)
      return if ids.empty?

      PersonGroupEntry.where(id: ids).update_all(person_group_id: @group.id, updated_at: Time.current)
    end

    # One statement for all of them. No validation runs: the check, the foreign keys and
    # the unique indexes of the table hold every rule of an entry.
    def add(added)
      return if added.empty?

      PersonGroupEntry.insert_all!(added.map do |entry|
        { person_group_id: @group.id, owner_id: current_user.id, organisation_id: entry.organisation_id, **entry.address }
      end)
    end

    # Groups left with fewer than two entries: by a deleted row, organisation or entry, and
    # by this merge, which takes the lines of a person out of a group and leaves the rest.
    # Counted on what is stored, not on what the viewer sees: a group whose other part is
    # hidden for want of a right stays.
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
