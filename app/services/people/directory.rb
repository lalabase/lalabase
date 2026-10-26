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
  #   finds nothing but "mueller" and "Müller" find each other) over name,
  #   function, department, company and email. In Ruby, because the member half
  #   reads its names from users; the list is sized for a few hundred rows per
  #   organisation. Pagination is a follow-up once an organisation passes that.
  class Directory
    KINDS = %w[all members contacts].freeze

    Entry = Struct.new(:kind, :user, :person, :sort_name, keyword_init: true) do
      def member?
        kind == :member
      end

      # The name the row stands for in search and order. A view shows a
      # member's name through viewer_display_name instead.
      def plain_name
        member? ? user.display_name : person.name
      end
    end

    def initialize(viewer:, organisation:, query: nil, kind: 'all')
      @viewer = viewer
      @organisation = organisation
      @query = PersonName.normalize(query)
      @kind = KINDS.include?(kind.to_s) ? kind.to_s : 'all'
    end

    def entries
      everyone.select { |entry| kind_matches?(entry) && (@query.blank? || matches?(entry)) }
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

    def matches?(entry)
      haystack = [entry.plain_name, entry.person&.function, entry.person&.department, entry.person&.company,
                  entry.person&.email, entry.user&.email]
      haystack.any? { |value| value.present? && PersonName.normalize(value).include?(@query) }
    end
  end
end
