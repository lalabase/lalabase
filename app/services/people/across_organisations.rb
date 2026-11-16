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
    Row = Data.define(:name, :kind, :function, :department, :company, :last_contact, :sources, :avatar_user)

    # One entry of one organisation. fields: People::Lookup.row of the entry, its :id the
    # entry's address ("person:<uuid>" or "member:<uuid>"). lane: what opens the entry on
    # that organisation's people page ({ person_id: } or { member_id: }).
    Source = Data.define(:organisation_id, :organisation_name, :lane, :fields)

    # One entry while the list is built: never handed out.
    Candidate = Struct.new(:organisation, :listing, :entry, :group, :matched)
    private_constant :Candidate

    def self.call(viewer:, query: nil, org: nil, page: 1)
      new(viewer: viewer, query: query, org: org, page: page).call
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
      people = candidates.group_by(&:group).values.select { |sources| sources.any?(&:matched) }
      people.each_with_index.sort_by { |sources, index| [sources.first.entry.sort_name, index] }.map(&:first)
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
      people.map { |candidates| row_of(candidates.first.entry.user, sources.values_at(*candidates)) }
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

    def row_of(account, sources)
      fields = sources.map(&:fields)
      Row.new(name: fields.first[:name], kind: fields.first[:kind], sources: sources.freeze, avatar_user: account,
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
