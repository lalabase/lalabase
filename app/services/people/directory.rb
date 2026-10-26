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
      return [] unless PersonPolicy.view_allowed?(@viewer, @organisation)

      ActsAsTenant.with_tenant(@organisation) do
        list = []
        list.concat(member_entries) unless @kind == 'contacts'
        list.concat(contact_entries) unless @kind == 'members'
        list.select! { |entry| matches?(entry) } if @query.present?
        list.sort_by { |entry| [entry.sort_name, entry.person&.id.to_s, entry.user&.id.to_s] }
      end
    end

    private

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
