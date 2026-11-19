# frozen_string_literal: true

# The people of every organisation a person is an active member of, as ONE list: the read of
# the page above the organisations (GET /people, AllPeopleController).
module People
  # * Stays inside the tenant, as every read for a signed-in person should: it walks the
  #   organisations the viewer is an ACTIVE member of and reads each of them under
  #   ActsAsTenant.with_tenant, through People::Lookup (the one read of the directory). No
  #   query reads across organisations, and the tenant is lifted nowhere.
  # * A reference is not a right: only what the read of an organisation returned is shown. An
  #   organisation where the viewer lacks the people right (PersonPolicy.view_allowed?) is
  #   skipped before anything is read; it contributes no row and is not named, not in a row
  #   and not among #organisations (the options of the filter).
  # * One person per account: member entries with the same account are one row with several
  #   sources. Computed here on every read, stored nowhere. A contact is a row of its own,
  #   whatever its name: two rows called alike in two organisations stay two.
  # * The viewer's own merges (PersonGroup) join more: every entry a group names that this
  #   read returned joins the other entries of that group. A group is held by id against
  #   the entries of the directories, never loaded from: an entry the viewer cannot see
  #   just now (no right there any more, the row gone) is not shown and not counted, and
  #   a group with one visible entry is an ordinary row. The group itself stays as it is.
  #   The account rule comes first and is never undone; an entry joins a person only while
  #   that person has no source of its organisation yet (one source per organisation).
  # * The search is the directory's own (People::Directory#matches?), asked per organisation.
  #   A match on any entry shows the whole person: the other sources come from the full
  #   directory of their organisation, not from the filtered one.
  # * One directory per organisation and request (People::Lookup#listing). The page is cut
  #   after the merge, so the last contacts are read in a second pass, for the rows of the
  #   page shown only, again under each organisation's tenant.
  # * Plain values leave: a Row and its Sources hold strings, ids and the hash of
  #   People::Lookup.row (who it is and what they do, no contact details, no notes). No
  #   Person leaves, so a view cannot load more from one after the tenant is gone. The one
  #   record is Row#avatar_user, a member's account for the picture: User carries no tenant.
  # * The writes of a merge ask this read what the list shows (#part, #person_with,
  #   #names?, #merges_shown_with): they act on the people as they are shown, not on the
  #   lines as they are stored, and the rule of who is shown as one person stays here.
  # * The card of one person asks the same (#shown_at, People::MergedCard): the sources the
  #   list shows as that person, each handed to the caller's block under its own tenant.
  # * The lead source of a person (.lead_of, D11) is decided by ONE rule for the row and
  #   for the card: the most values (People::Lookup.value_count, counted under the tenant
  #   of each source), then the newest last contact, then the order of the list. It is a
  #   value of its own: the sources keep the order of the list, and the name, the kind and
  #   the address of a row and of a card stay the first source's.
  # * Whether one source can leave a merge alone is asked of the same rule, never of a
  #   second one: the people are grouped again, in memory, without the lines that would go
  #   (#shown_at's detachable), and after the write by the lines stored now
  #   (#stands_alone_now?). A card offers what the write accepts, and the write checks
  #   every person of the list, not only the one it changed.
  class AcrossOrganisations
    PER_PAGE = 50

    # `org` names no organisation the list can show: a malformed id, a missing or foreign
    # organisation, a deactivated membership, an organisation without the people right. One
    # answer for all of them.
    class UnknownOrganisation < StandardError; end

    # rows: the rows of the page shown. organisations: [{ id:, name: }], the organisations
    # that contribute, by name. total: the people before the cut.
    Result = Data.define(:rows, :organisations, :total, :page, :pages, :per_page)

    # One person. name, kind: of the first source (the sources stand in the order of the
    # organisations' names). function, department, company: of the first source that has
    # one. last_contact: { on:, kind: } of People::Lookup.row, the newest of the sources.
    # merge_id: the id of the viewer's merge that joined sources of this row, nil for a row
    # no merge joined (also one the account rule alone made). lead: the organisation id of
    # the lead source (.lead_of), the one the row names first.
    Row = Data.define(:name, :kind, :function, :department, :company, :last_contact, :sources, :avatar_user, :merge_id, :lead)

    # One entry of one organisation. fields: People::Lookup.row of the entry, its :id the
    # entry's address ("person:<uuid>" or "member:<uuid>"). lane: what opens the entry on
    # that organisation's people page ({ person_id: } or { member_id: }). value_count: how
    # many values the card of the entry shows (People::Lookup.value_count), for the lead.
    Source = Data.define(:organisation_id, :organisation_name, :lane, :fields, :value_count) do
      # The last contact of the entry, { on:, kind: } or nil: for .lead_of.
      def last_contact = fields[:last_contact]
    end

    # One entry as a write of a merge stores it (Actors::MergePeople): where it is, its
    # address (PersonGroupEntry.address_of) and the keys a stored entry names it by
    # (PersonGroupEntry.keys_for). Ids only.
    Part = Data.define(:organisation_id, :address, :keys) do
      # The account behind the entry (a member's, or the one a deactivated member's row
      # still carries), nil for a contact.
      def account
        keys.filter_map { |_organisation_id, kind, id| id if kind == :account }.first
      end
    end

    # One person for a card (#shown_at). sources: what the caller's block answered for each
    # source, in the order of the list. merge_id: as Row#merge_id.
    Shown = Data.define(:merge_id, :sources)

    # One entry while the list is built: never handed out.
    Candidate = Struct.new(:organisation, :listing, :entry, :group, :matched, :merge_id)
    private_constant :Candidate

    # The lead of a person's sources (D11), as an organisation id: the source with the most
    # values on the card, on a tie the one with the newest last contact, then the first in
    # the order given (the order of the list). The one rule for a row (Row#lead) and for
    # the card (People::MergedCard::Card#lead). A source answers organisation_id,
    # value_count and last_contact ({ on: "YYYY-MM-DD" } or nil). nil for no sources.
    def self.lead_of(sources)
      ranked = sources.each_with_index.max_by do |source, index|
        [source.value_count, source.last_contact&.dig(:on).to_s, -index]
      end
      ranked&.first&.organisation_id
    end

    def self.call(viewer:, query: nil, org: nil, page: 1)
      new(viewer: viewer, query: query, org: org, page: page).call
    end

    # Membership release uses the same visible row/account aliases as the reader. No
    # private fields or records leave an organisation's tenant, only address triples.
    def self.aliases_for(viewer:)
      new(viewer: viewer).entry_aliases
    end

    def initialize(viewer:, query: nil, org: nil, page: 1)
      @viewer = viewer
      @query = query.is_a?(String) ? query.strip.presence : nil
      @org = org
      @page = page
    end

    def call
      open = open_listings
      people = merged_people(narrowed(open))
      page, pages = paging(people.size)

      Result.new(rows: rows_of(people.slice((page - 1) * PER_PAGE, PER_PAGE)), total: people.size,
                 page: page, pages: pages, per_page: PER_PAGE, organisations: named(open))
    end

    def entry_aliases
      open_listings.flat_map do |organisation, listing|
        in_people_organisation(organisation) do
          listing.entries.filter_map { |entry| row_alias(organisation, entry) }
        end
      end
    end

    # What a write of a merge asks (Actors::MergePeople, Actors::SplitPerson), of ONE
    # instance without search, filter or page: every directory is read once for all of it.
    # #entry_aliases, #part and #names? read no merge. #person_with and #merges_shown_with
    # read the stored merges at their first call and keep the answer, so a write settles
    # its lines before it asks them (PersonGroupEntry.settle_for_owner).
    # #stands_alone_now? reads them once more, after the write.

    # The entry an id names in the directory of an organisation, as the viewer may read it
    # there. nil for everything else: an organisation that does not contribute (not the
    # viewer's, a deactivated membership, no people right), an unknown or malformed id.
    def part(organisation_id, id)
      organisation, listing = open_listings.find { |one, _listing| one.id == organisation_id }
      return unless listing

      entry = in_people_organisation(organisation) { listing.entry(id) }
      candidate = every_candidate.find { |one| one.entry.equal?(entry) } if entry
      part_of(candidate) if candidate
    rescue People::Lookup::InvalidArgument
      nil
    end

    # The person the list shows a part in: every source of that row. The same object for
    # every part of one person, so a caller holds two people apart by identity.
    def person_with(part)
      list = shown_people.fetch(@candidate_of.fetch(part))
      (@people ||= {}.compare_by_identity)[list] ||= list.map { |candidate| part_of(candidate) }.freeze
    end

    # The person an address names, for the card of that person (People::MergedCard): the
    # entry itself (#part: nil for everything the viewer cannot see there) and every other
    # source the list shows as the same person. The block runs once per source UNDER THE
    # TENANT OF ITS ORGANISATION, with the organisation, the entry (its last contact
    # attached) and whether that source is detachable; what it answers is collected. The
    # caller reads everything it shows inside the block and hands out plain values, as the
    # list does: after it the tenant is gone.
    #
    # Detachable: a merge joined the person, the account rule alone would show more than
    # two people (with two, taking one out is dissolving the merge), and without the lines
    # of the person's merges that name this source (what Actors::SplitPerson deletes) the
    # source stands alone and every other person of the list stays as shown. A source the
    # account joins to another one, and one whose leaving would let a competing merge pull
    # in someone else, is not.
    def shown_at(organisation_id, id)
      part = part(organisation_id, id)
      return unless part

      candidates = shown_people.fetch(@candidate_of.fetch(part))
      merge_id = candidates.first.merge_id
      several = candidates.map(&:group).uniq.size > 2
      sources = candidates.map do |candidate|
        detachable = !merge_id.nil? && several && leaves_alone?(candidate)
        in_people_organisation(candidate.organisation) do
          candidate.entry.last_contact = candidate.listing.last_contacts_for([candidate.entry]).first
          yield candidate.organisation, candidate.entry, detachable
        end
      end
      Shown.new(merge_id: merge_id, sources: sources)
    end

    # After a write that took the lines naming a part out of its person's merges
    # (Actors::SplitPerson, under the owner lock): whether the lines stored NOW show the
    # part alone and every other person of the list as it was shown before. The stored
    # lines are read once more and the same entries grouped by them; no directory is read
    # again. "As shown before" is what this instance read BEFORE the write (#person_with,
    # #merges_shown_with): read first after it, both sides would be the new lines and the
    # check would hold for any person that came apart. So it refuses to answer instead.
    def stands_alone_now?(part)
      raise ArgumentError, 'read the people as shown before the write (#merges_shown_with)' unless @shown_people

      candidate = @candidate_of.fetch(part)
      people_of(regrouped(lines_for(every_candidate))) == apart(candidate)
    end

    # Whether a stored entry with this key (PersonGroupEntry#key) names an entry the viewer
    # can see just now, in any organisation.
    def names?(key)
      @named ||= every_candidate.flat_map { |one| PersonGroupEntry.keys_for(one.organisation.id, one.entry) }.to_set
      @named.include?(key)
    end

    # The merges that join the person a merge joins, itself included: what "undo" has to
    # take apart for the row to fall apart. Empty for a merge the list does not show.
    def merges_shown_with(merge_id)
      shown_people
      @merges_of.each_value.find { |ids| ids.include?(merge_id) } || []
    end

    private

    # The organisations that contribute, by name, each with the listing of its ONE
    # directory. Only the rights question is asked here; a listing reads when it is asked.
    def open_listings
      @open_listings ||= @viewer.active_organisations.by_name.to_a.filter_map do |organisation|
        in_people_organisation(organisation) do
          lookup = People::Lookup.new(viewer: @viewer, organisation: organisation)
          [organisation, lookup.listing(query: @query)] if lookup.allowed?
        end
      end
    end

    # For the writes: every entry of every organisation once, and the person each is shown in.
    def every_candidate
      @every_candidate ||= open_listings.flat_map { |organisation, listing| candidates_in(organisation, listing) }
    end

    # Every person of the list, by each of its candidates. Keeps the lists themselves
    # (@shown_lists) and the merges that joined each of them (@merges_of).
    def shown_people
      @shown_people ||= begin
        @shown_lists, @merges_of = joined_by_merges(every_candidate, merges_among(every_candidate, every_lines))
        @shown_lists.each_with_object({}.compare_by_identity) { |list, found| list.each { |candidate| found[candidate] = list } }
      end
    end

    # The stored lines the list was shown by, read once.
    def every_lines
      @every_lines ||= lines_for(every_candidate)
    end

    # Whether the candidate's person stays as shown without the lines of its merges that
    # name it, with the candidate alone (#shown_at). In memory: the lines as shown, less
    # those an Actors::SplitPerson with this source would delete.
    def leaves_alone?(candidate)
      list = shown_people.fetch(candidate) # reads @merges_of first
      merges = @merges_of.fetch(list, [])
      keys = PersonGroupEntry.keys_for(candidate.organisation.id, candidate.entry).to_set
      lines = every_lines.reject { |merge_id, *address| merges.include?(merge_id) && keys.include?(PersonGroupEntry.key_of(*address)) }
      people_of(regrouped(lines)) == apart(candidate)
    end

    # Every candidate grouped by these lines, the way the list groups them.
    def regrouped(lines)
      grouped(every_candidate, merges_among(every_candidate, lines)).first
    end

    # The people as shown, with the candidate taken out of its person and alone.
    def apart(candidate)
      list = shown_people.fetch(candidate)
      @shown_sets ||= people_of(@shown_lists)
      (@shown_sets - [ids_of(list)]) | people_of([list.reject { |one| one.equal?(candidate) }, [candidate]])
    end

    # People compared by who is with whom, whatever the order: a set of sets of candidates.
    def people_of(lists)
      lists.reject(&:empty?).to_set { |list| ids_of(list) }
    end

    def ids_of(list)
      list.to_set(&:object_id)
    end

    def part_of(candidate)
      @candidate_of ||= {}.compare_by_identity
      (@part_of ||= {}.compare_by_identity)[candidate] ||= begin
        organisation_id = candidate.organisation.id
        part = Part.new(organisation_id: organisation_id, address: PersonGroupEntry.address_of(candidate.entry).freeze,
                        keys: PersonGroupEntry.keys_for(organisation_id, candidate.entry).freeze)
        @candidate_of[part] = candidate
        part
      end
    end

    def named(open)
      open.map { |organisation, _listing| { id: organisation.id, name: organisation.name } }
    end

    # All of them, or the one `org` names among them. An empty `org` is no filter (the
    # select's "all").
    def narrowed(open)
      return open if @org.nil? || @org == ''

      id = Lalabase::Uuid.dashed(@org) if @org.is_a?(String)
      chosen = open.select { |organisation, _listing| organisation.id == id }
      raise UnknownOrganisation if id.nil? || chosen.empty?

      chosen
    end

    # The people as lists of candidates, one list per person, sorted by name. A person is
    # listed when the search matched any of their entries.
    def merged_people(open)
      candidates = open.flat_map { |organisation, listing| candidates_in(organisation, listing) }
      people, = joined_by_merges(candidates, merges_among(candidates, lines_for(candidates)))
      people = people.select { |sources| sources.any?(&:matched) }
      people.each_with_index.sort_by { |sources, index| [sources.first.entry.sort_name, index] }.map(&:first)
    end

    # The people of #grouped, and each candidate learns the merge that joined it
    # (Candidate#merge_id, for Row#merge_id and Shown#merge_id).
    def joined_by_merges(candidates, merges)
      people, merges_of, merge_ids = grouped(candidates, merges)
      merge_ids.each { |candidate, merge_id| candidate.merge_id = merge_id }
      [people, merges_of]
    end

    # The account rule first (one list per account or contact), then the viewer's merges on
    # top of it. The sources of a person keep the order of the organisations' names, and
    # the people the order of their first source. Touches no candidate, so the same
    # candidates can be grouped again by other lines (#leaves_alone?, #stands_alone_now?).
    # Answers the people as lists of candidates, the merges that joined each list (by the
    # list, #merges_shown_with) and the merge that joined each candidate.
    def grouped(candidates, merges)
      merges_of = {}.compare_by_identity
      merge_ids = {}.compare_by_identity
      people = candidates.group_by(&:group).values
      return [people, merges_of, merge_ids] if merges.empty?

      order = candidates.each_with_index.to_h.compare_by_identity
      person_of = people.each_with_object({}.compare_by_identity) { |list, found| list.each { |one| found[one] = list } }
      in_list_order(merges, order).each { |merge_id, named| join(named, merge_id, person_of, merges_of, merge_ids) }
      people = person_of.values.uniq(&:object_id).each { |list| list.sort_by! { |one| order[one] } }
                        .sort_by { |list| order[list.first] }
      [people, merges_of, merge_ids]
    end

    # The candidates of every merge in the order of the list (the organisations' names,
    # then the names inside one), and the merges in the order of their first candidate. A
    # merge that collides with the account rule or with another merge (#join) is then
    # decided by what the viewer sees, the same way on every read: the order the entries
    # are stored in is the order of their random ids and must decide nothing.
    # Row/account aliases have already been settled, before the visibility cutoff. Then
    # the rest of the candidates decides, and at last the id, so the order is total.
    def in_list_order(merges, order)
      merges.map { |merge_id, named| [merge_id, named.sort_by { |candidate| order[candidate] }] }
            .sort_by { |merge_id, named| [order[named.first], named.map { |candidate| order[candidate] }, merge_id.to_s] }
    end

    # The viewer's stored lines as [merge id, *PersonGroupEntry::KEY_COLUMNS], settled
    # against the row/account aliases of these candidates (PersonGroupEntry.settled_lines).
    # ONE statement on a table without a tenant. With fewer than two organisations in the
    # list there is nothing a merge could join, and nothing is read.
    def lines_for(candidates)
      return [] if candidates.map(&:organisation).uniq.size < 2

      lines = PersonGroupEntry.owned_by(@viewer).pluck(:person_group_id, *PersonGroupEntry::KEY_COLUMNS)
      return lines if lines.empty?

      aliases = candidates.filter_map { |candidate| row_alias(candidate.organisation, candidate.entry) }
      PersonGroupEntry.settled_lines(lines, aliases: aliases)
    end

    # The viewer's merges as [merge id, the candidates it names], from settled lines
    # (#lines_for). The entries are held by id against what the directories returned
    # (PersonGroupEntry.keys_for).
    def merges_among(candidates, lines)
      return [] if lines.empty?

      by_key = candidates.each_with_object({}) do |candidate, found|
        PersonGroupEntry.keys_for(candidate.organisation.id, candidate.entry).each { |key| found[key] = candidate }
      end
      lines.group_by(&:first).filter_map { |merge_id, named| merge_of(merge_id, named, by_key) }
    end

    def row_alias(organisation, entry)
      account = PersonGroupEntry.account_of(entry)
      [organisation.id, entry.person.id, account] if entry.person && account
    end

    # One merge held against the candidates; nil when it names fewer than two of them.
    def merge_of(merge_id, lines, by_key)
      visible = lines.filter_map { |_id, *address| by_key[PersonGroupEntry.key_of(*address)] }.uniq(&:object_id)
      [merge_id, visible] if visible.size > 1
    end

    # Joins the people of the candidates one merge names into the person of the first. A
    # person that already holds a source of the same organisation stays apart: the account
    # rule may have brought that source since the merge was written.
    def join(named, merge_id, person_of, merges_of, merge_ids)
      target = person_of[named.first]
      named.drop(1).each do |candidate|
        other = person_of[candidate]
        next if other.equal?(target) || target.map(&:organisation).intersect?(other.map(&:organisation))

        merges_of[target] = [*merges_of[target], *merges_of.delete(other), merge_id].uniq
        target.concat(other).each do |one|
          person_of[one] = target
          merge_ids[one] ||= merge_id
        end
      end
    end

    # Every entry of the organisation, marked when the search matched it. Without a search
    # everything matches and the directory is asked once.
    def candidates_in(organisation, listing)
      in_people_organisation(organisation) do
        matched = Set.new.compare_by_identity.merge(listing.matches) if @query
        listing.entries.map do |entry|
          Candidate.new(organisation: organisation, listing: listing, entry: entry,
                        group: group_of(organisation, entry), matched: matched.nil? || matched.include?(entry))
        end
      end
    end

    # What makes two entries one person: the account of a member, nothing else. A contact
    # (also the row a former member left) is alone in its group.
    def group_of(organisation, entry)
      entry.member? ? [:member, entry.user.id] : [:contact, organisation.id, entry.person.id]
    end

    # The page asked for, held inside what there is, and the number of pages. Anything that
    # is no whole number is the first page; a number beyond the list, however long, the last.
    def paging(total)
      pages = [(total / PER_PAGE.to_f).ceil, 1].max
      number = @page.to_s.match?(/\A\d+\z/) ? @page.to_s.to_i : 1
      [number.clamp(1, pages), pages]
    end

    def rows_of(people)
      sources = sources_by_candidate(people.flatten)
      people.map do |candidates|
        row_of(candidates.first.entry.user, sources.values_at(*candidates), candidates.first.merge_id)
      end
    end

    # The sources of the page are read per organisation, under that tenant.
    def sources_by_candidate(candidates)
      candidates.group_by(&:organisation).each_with_object({}.compare_by_identity) do |(organisation, list), found|
        in_people_organisation(organisation) do
          list.zip(sources_of(list)) { |candidate, source| found[candidate] = source }
        end
      end
    end

    # The sources of some entries of ONE organisation, in their order: the last contacts
    # for these entries only, then the plain values.
    def sources_of(candidates)
      entries = candidates.map(&:entry)
      lasts = candidates.first.listing.last_contacts_for(entries)
      candidates.each_with_index.map do |candidate, index|
        entries[index].last_contact = lasts[index]
        source_of(candidate.organisation, entries[index])
      end
    end

    # Under the tenant of the organisation (#sources_by_candidate): the count reads the
    # card of the entry, in memory, from what the directory loaded.
    def source_of(organisation, entry)
      lane = entry.person ? { person_id: entry.person.id } : { member_id: entry.user.id }
      Source.new(organisation_id: organisation.id, organisation_name: organisation.name,
                 lane: lane, fields: People::Lookup.row(entry).freeze,
                 value_count: People::Lookup.value_count(People::Lookup.card(entry)))
    end

    def row_of(account, sources, merge_id)
      fields = sources.map(&:fields)
      Row.new(name: fields.first[:name], kind: fields.first[:kind], sources: sources.freeze, avatar_user: account,
              merge_id: merge_id, lead: self.class.lead_of(sources),
              last_contact: fields.filter_map { |row| row[:last_contact] }.max_by { |last| last[:on] },
              **first_values(fields))
    end

    # function, department and company of the first source that has one.
    def first_values(fields)
      %i[function department company].index_with { |field| fields.filter_map { |row| row[field].presence }.first }
    end

    # Named so the loop per organisation has its own frame in the Prosopite stack
    # (spec/support/prosopite.rb): bounded by the viewer's organisations.
    def in_people_organisation(organisation, &)
      ActsAsTenant.with_tenant(organisation, &)
    end
  end
end
