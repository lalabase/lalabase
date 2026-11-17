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
    # no merge joined (also one the account rule alone made).
    Row = Data.define(:name, :kind, :function, :department, :company, :last_contact, :sources, :avatar_user, :merge_id)

    # One entry of one organisation. fields: People::Lookup.row of the entry, its :id the
    # entry's address ("person:<uuid>" or "member:<uuid>"). lane: what opens the entry on
    # that organisation's people page ({ person_id: } or { member_id: }).
    Source = Data.define(:organisation_id, :organisation_name, :lane, :fields)

    # One entry while the list is built: never handed out.
    Candidate = Struct.new(:organisation, :listing, :entry, :group, :matched, :merge_id)
    private_constant :Candidate

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

    private

    # The organisations that contribute, by name, each with the listing of its ONE
    # directory. Only the rights question is asked here; a listing reads when it is asked.
    def open_listings
      @viewer.active_organisations.by_name.to_a.filter_map do |organisation|
        in_people_organisation(organisation) do
          lookup = People::Lookup.new(viewer: @viewer, organisation: organisation)
          [organisation, lookup.listing(query: @query)] if lookup.allowed?
        end
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
      people = joined_by_merges(candidates).select { |sources| sources.any?(&:matched) }
      people.each_with_index.sort_by { |sources, index| [sources.first.entry.sort_name, index] }.map(&:first)
    end

    # The account rule first (one list per account or contact), then the viewer's merges on
    # top of it. The sources of a person keep the order of the organisations' names, and
    # the people the order of their first source.
    def joined_by_merges(candidates)
      people = candidates.group_by(&:group).values
      merges = merges_among(candidates)
      return people if merges.empty?

      order = candidates.each_with_index.to_h.compare_by_identity
      person_of = people.each_with_object({}.compare_by_identity) { |list, found| list.each { |one| found[one] = list } }
      in_list_order(merges, order).each { |merge_id, named, _by_row| join(named, merge_id, person_of) }
      person_of.values.uniq(&:object_id).map { |list| list.sort_by { |one| order[one] } }
               .sort_by { |list| order[list.first] }
    end

    # The candidates of every merge in the order of the list (the organisations' names,
    # then the names inside one), and the merges in the order of their first candidate. A
    # merge that collides with the account rule or with another merge (#join) is then
    # decided by what the viewer sees, the same way on every read: the order the entries
    # are stored in is the order of their random ids and must decide nothing.
    # Row/account aliases have already been settled, before the visibility cutoff. Then
    # the rest of the candidates decides, and at last the id, so the order is total.
    def in_list_order(merges, order)
      merges.map { |merge_id, named, by_row| [merge_id, named.sort_by { |candidate| order[candidate] }, by_row] }
            .sort_by do |merge_id, named, _by_row|
              [order[named.first], named.map { |candidate| order[candidate] }, merge_id.to_s]
            end
    end

    # The viewer's merges as [merge id, the candidates it names, those of them it names by
    # their row]. ONE statement on a table without a tenant; the entries are held by id
    # against what the directories returned (PersonGroupEntry.keys_for). With fewer than
    # two organisations in the list there is nothing a merge could join.
    def merges_among(candidates)
      return [] if candidates.map(&:organisation).uniq.size < 2

      named = PersonGroupEntry.owned_by(@viewer).pluck(:person_group_id, *PersonGroupEntry::KEY_COLUMNS)
      return [] if named.empty?

      by_key = candidates.each_with_object({}) do |candidate, found|
        PersonGroupEntry.keys_for(candidate.organisation.id, candidate.entry).each { |key| found[key] = candidate }
      end
      aliases = candidates.filter_map { |candidate| row_alias(candidate.organisation, candidate.entry) }
      named = PersonGroupEntry.settled_lines(named, aliases: aliases)
      named.group_by(&:first).filter_map { |merge_id, lines| merge_of(merge_id, lines, by_key) }
    end

    def row_alias(organisation, entry)
      account = entry.user&.id || entry.person&.user_id
      [organisation.id, entry.person.id, account] if entry.person && account
    end

    # One merge held against the candidates; nil when it names fewer than two of them.
    def merge_of(merge_id, lines, by_key)
      found = lines.filter_map do |_id, organisation_id, person_id, user_id|
        candidate = by_key[PersonGroupEntry.key_of(organisation_id, person_id, user_id)]
        [candidate, person_id.present?] if candidate
      end
      visible = found.map(&:first).uniq(&:object_id)
      [merge_id, visible, found.select(&:last).map(&:first)] if visible.size > 1
    end

    # Joins the people of the candidates one merge names into the person of the first. A
    # person that already holds a source of the same organisation stays apart: the account
    # rule may have brought that source since the merge was written.
    def join(named, merge_id, person_of)
      target = person_of[named.first]
      named.drop(1).each do |candidate|
        other = person_of[candidate]
        next if other.equal?(target) || target.map(&:organisation).intersect?(other.map(&:organisation))

        target.concat(other).each do |one|
          person_of[one] = target
          one.merge_id ||= merge_id
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

    def source_of(organisation, entry)
      lane = entry.person ? { person_id: entry.person.id } : { member_id: entry.user.id }
      Source.new(organisation_id: organisation.id, organisation_name: organisation.name,
                 lane: lane, fields: People::Lookup.row(entry).freeze)
    end

    def row_of(account, sources, merge_id)
      fields = sources.map(&:fields)
      Row.new(name: fields.first[:name], kind: fields.first[:kind], sources: sources.freeze, avatar_user: account,
              merge_id: merge_id,
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
