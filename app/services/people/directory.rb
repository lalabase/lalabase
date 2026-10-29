# frozen_string_literal: true

# Read object for the people directory page (Organisations::PeopleController).
#
# Entry point: entries
module People
  # The people directory of one organisation as a viewer sees it: the members
  # they may see on the members page, each with their person row if one exists,
  # and the person rows without an active member behind them (contacts).
  #
  # * Member half: MembershipPolicy::Scope, active memberships only, the same
  #   reach as the members page. A member of a project the viewer cannot see is
  #   not listed, and neither is their person row (PersonPolicy::Scope).
  # * Contact half: rows without a link, and rows linked to someone who is no
  #   longer an active member (name from the row itself).
  # * Search: one normalized substring match (PersonName.normalize, so "Muller"
  #   finds nothing but "mueller" and "Müller" find each other) over name
  #   (with the salutation in front: "Frau Müller"), function, department,
  #   company, email and the values of the additional details (never their
  #   labels, PersonDetail.search_values). In Ruby, because the member half
  #   reads its names from users; the list is sized for a few hundred rows per
  #   organisation. Pagination is a follow-up once an organisation passes that.
  class Directory
    KINDS = %w[all members contacts].freeze
    # The orders of the list (E5): by name (the default) or by last contact,
    # newest first, people without any contact last.
    SORTS = %w[name last].freeze

    # last_contact: People::Contacts::LastContact or nil, set for the entries
    # the page shows (#entries).
    Entry = Struct.new(:kind, :user, :person, :sort_name, :last_contact, keyword_init: true) do
      def member?
        kind == :member
      end

      # The name the row stands for in search and order. A view shows a
      # member's name through viewer_display_name instead.
      def plain_name
        member? ? user.display_name : person.name
      end

      # The line under the name, in the list and in the link dialog: function
      # and company of the row, else the email a member shows to others
      # (User#shown_email, nil when they show none), else the salutation (two
      # contacts called "Müller" are "Frau" and "Herr"). A contact without any
      # has none (nil). A contact never shows an email here: the row's own
      # email is a field of its page, not a label.
      def detail
        [person&.function, person&.company].compact_blank.join(' · ').presence ||
          (user&.shown_email if member?) || person&.salutation
      end
    end

    def initialize(viewer:, organisation:, query: nil, kind: 'all', sort: 'name')
      @viewer = viewer
      @organisation = organisation
      @query = PersonName.normalize(query)
      @kind = KINDS.include?(kind.to_s) ? kind.to_s : 'all'
      @sort = SORTS.include?(sort.to_s) ? sort.to_s : 'name'
    end

    # The entries the page shows, each with its last contact (People::Contacts,
    # only what the viewer may read), in the order asked for.
    def entries
      list = everyone.select { |entry| kind_matches?(entry) && (@query.blank? || matches?(entry)) }
      attach_last_contacts(list)
      @sort == 'last' ? by_last_contact(list) : list
    end

    # The one subject People::Contacts asks about for an entry: a member counts
    # their own ticket work, a contact (also a former member) only meetings.
    def self.contact_subject(entry)
      People::Contacts::Subject.for(person: entry.person, member: (entry.user if entry.member?))
    end

    # The last contact of each entry, in the order given (People::Contacts, only
    # what the viewer may read; nil: none). The list asks for all its rows at
    # once (#entries), the assistant's get_person for one (People S3).
    def last_contacts_for(list)
      return [] if list.empty?

      contacts = People::Contacts.new(viewer: @viewer, organisation: @organisation)
      ActsAsTenant.with_tenant(@organisation) do
        contacts.last_contacts(list.map { |entry| self.class.contact_subject(entry) })
      end
    end

    # How many people the page holds, before search and filter: the head line
    # and the three filters (all, members, contacts) count the same list.
    def counts
      members = everyone.count(&:member?)
      { 'all' => everyone.size, 'members' => members, 'contacts' => everyone.size - members }
    end

    # The member half's entry for one account, or nil when the viewer may not
    # see that member (or it is no active member): the lane of a member who has
    # no row of their own yet.
    def member_entry(user_id)
      everyone.find { |entry| entry.member? && entry.user.id == user_id.to_s }
    end

    # The entry of one person row, or nil when the viewer may not see it. A row
    # of an active member the viewer sees is that member's entry.
    def person_entry(person_id)
      everyone.find { |entry| entry.person&.id == person_id.to_s }
    end

    # The contact entry of a former member: their row, which keeps the meetings
    # they still carry by account (People::Contacts reads the row's user_id).
    def former_member_entry(user_id)
      everyone.find { |entry| !entry.member? && entry.person&.user_id == user_id.to_s }
    end

    # The entry a meeting participant stands for, or nil when the viewer may
    # not see it (or it is a free name). A participant carries one key:
    # * user_id: the member, or, once the membership is gone or inactive, the
    #   row that keeps their meetings (former_member_entry);
    # * person_id: that row, which is a member's entry when the row belongs to
    #   an active member (person_entry).
    def entry_for_participant(participant)
      if participant.user_id
        member_entry(participant.user_id) || former_member_entry(participant.user_id)
      elsif participant.person_id
        person_entry(participant.person_id)
      end
    end

    # The entries matching the search, without last contacts: the list of the
    # dialog that links a meeting participant (S2b).
    def candidates
      everyone.select { |entry| @query.blank? || matches?(entry) }
    end

    # The entries that may be the participant of this name (E6): the same full
    # normalized name first, then the same surname. A suggestion only; nothing
    # is linked without a click.
    def suggestions_for(name)
      full = PersonName.normalize(name)
      surname = self.class.surname(name)
      return [] if full.blank?

      same_name = everyone.select { |entry| entry.sort_name == full }
      same_surname = surname ? everyone.select { |entry| self.class.surname(entry.plain_name) == surname } : []
      (same_name + same_surname).uniq
    end

    # The last word of a name, normalized, without a note in brackets and
    # without initials: "J. Weber (Hoster)" -> "weber". Nil without one.
    def self.surname(name)
      words = PersonName.normalize(PersonName.without_note(name)).scan(/[[:alpha:]][[:alpha:]'-]*/)
      words.reverse.find { |word| word.length > 1 }
    end

    # The other entries with the same normalized name as this person: rows and
    # members that may be the same person (the duplicate hint, read only).
    def duplicates_of(person)
      own = everyone.find { |entry| entry.person&.id == person.id }
      name = own ? own.sort_name : person.normalized_name
      everyone.select do |entry|
        entry.sort_name == name && entry.person&.id != person.id &&
          !(entry.user && entry.user.id == person.user_id)
      end
    end

    private

    def attach_last_contacts(list)
      last_contacts_for(list).each_with_index { |last, index| list[index].last_contact = last }
    end

    # Newest first, without a contact last; the name order breaks ties.
    def by_last_contact(list)
      list.each_with_index.sort_by do |entry, index|
        at = entry.last_contact&.at
        [at ? 0 : 1, at ? -at.to_f : 0, index]
      end.map(&:first)
    end

    # Everything the viewer may see, sorted, read once per directory.
    def everyone
      @everyone ||= if PersonPolicy.view_allowed?(@viewer, @organisation)
                      ActsAsTenant.with_tenant(@organisation) { sorted(member_entries + contact_entries) }
                    else
                      []
                    end
    end

    def kind_matches?(entry)
      case @kind
      when 'members' then entry.member?
      when 'contacts' then !entry.member?
      else true
      end
    end

    def sorted(list)
      list.sort_by { |entry| [entry.sort_name, entry.person&.id.to_s, entry.user&.id.to_s] }
    end

    def member_entries
      memberships = MembershipPolicy::Scope.new(@viewer, Membership).resolve
                                           .where(organisation: @organisation, active: true)
                                           .includes(user: { avatar_attachment: :blob })
      users = memberships.filter_map(&:user)
      linked = people.where(user_id: users.map(&:id)).index_by(&:user_id)
      users.map do |user|
        Entry.new(kind: :member, user: user, person: linked[user.id], sort_name: PersonName.normalize(user.display_name))
      end
    end

    def contact_entries
      active_member_ids = Membership.where(organisation: @organisation, active: true).select(:user_id)
      rows = people.where(user_id: nil).or(people.where.not(user_id: active_member_ids))
      rows.map { |person| Entry.new(kind: :contact, user: nil, person: person, sort_name: person.normalized_name) }
    end

    def people
      @people ||= PersonPolicy::Scope.new(@viewer, Person).resolve
    end

    # A member's email is the one they show to others (User#shown_email); a
    # hidden login address and an email left on a member row are not shown, so
    # they are not searched either: a search must not confirm that an address
    # belongs to a member.
    def matches?(entry)
      email = entry.member? ? entry.user.shown_email : entry.person&.email
      addressed = [entry.person&.salutation, entry.plain_name].compact_blank.join(' ')
      haystack = [addressed, entry.person&.function, entry.person&.department, entry.person&.company, email,
                  *PersonDetail.search_values(entry.person&.additional_details)]
      haystack.any? { |value| value.present? && PersonName.normalize(value).include?(@query) }
    end
  end
end
