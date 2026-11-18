# frozen_string_literal: true

# The one read of the people directory outside the people page (People S3b): the
# assistant's find_people and get_person, the same two tools on /api/mcp, and
# GET /api/v1/organisations/:organisation_id/people (cli_rest_plan D5: one rule, several
# adapters). An adapter chooses how many rows it shows and whether a card carries the notes,
# nothing else.
#
# Entry point: find / entry / listing
module People
  # * Rights: PersonPolicy.view_allowed? (#allowed?), asked again by #find and #entry before
  #   anything is read, so an adapter that forgets to ask still reads nothing. It asks for an
  #   ACTIVE membership, so a deactivated member who still holds the right is refused too.
  # * Search: People::Directory, the page's own reach and match. The kind is checked here
  #   instead of being read as "all" the way the page does: a program would believe in a
  #   filter it never set.
  # * Ids: "person:<uuid>" for a contact, "member:<uuid>" for a member, the format of the link
  #   dialog (Meetings::ParticipantLinkChoice), so an entry has one address everywhere. An
  #   unknown id, one of another organisation and one the viewer may not see all answer nil.
  # * Fields: .row for a list, .card for one person, and nowhere else. The notes go out only
  #   with notes: true, which only the REST card passes (S3b E2 B): free text about a third
  #   person, never sent to an AI provider and never in a list.
  # * Tokens: .for_token, which organisations a Personal Access Token may read (S3b E1).
  # * A list over several organisations (the people above the organisations) asks #listing,
  #   once per organisation: everything it needs of this one, from ONE directory.
  #
  # The organisation's tenant is the caller's to set: the assistant runs under it, the MCP
  # tools and the REST controller set it before they call (People::Directory sets it again
  # for its own reads).
  class Lookup
    KINDS = People::Directory::KINDS
    KIND_ERROR = "kind must be one of: #{KINDS.join(', ')}".freeze
    # The two kinds of id the list hands out; the link dialog's third value ("new") is none.
    ADDRESSES = %i[person member].freeze
    ID_ERROR = 'invalid id (expected "person:<uuid>" or "member:<uuid>")'

    # The viewer may not see the directory of this organisation.
    class Refused < StandardError; end
    # An argument the lookup cannot take: an unknown kind, an id of another shape.
    class InvalidArgument < ArgumentError; end

    # entries: the entries from offset on, at most limit; total: how many matched before the cut.
    Page = Data.define(:entries, :total)

    # One organisation's part of a list over several: every entry, the matches of the
    # search and the last contacts of a given list, all from ONE People::Directory, so the
    # organisation is read once however the caller cuts its page. #find attaches a last
    # contact to every match before it cuts; a list that merges organisations cuts after
    # the merge and asks for the last contacts of the rows it shows.
    class Listing
      def initialize(directory:)
        @directory = directory
      end

      # Every entry the viewer may see, sorted by name, without last contacts.
      def entries
        @directory.all_entries
      end

      # The entries matching the search (all of them without one), without last contacts:
      # the same objects as in #entries.
      def matches
        @directory.candidates
      end

      # The entry an id names, without its last contact, or nil: Lookup#entry for a caller
      # that holds the listing already. One of the objects of #entries.
      def entry(id)
        choice = Meetings::ParticipantLinkChoice.parse(id.to_s)
        raise InvalidArgument, ID_ERROR unless choice && ADDRESSES.include?(choice.kind)

        choice.kind == :member ? @directory.member_entry(choice.id) : @directory.person_entry(choice.id)
      end

      # The last contact of each entry of a list, in the order given (nil: none).
      delegate :last_contacts_for, to: :@directory
    end

    attr_reader :organisation

    def initialize(viewer:, organisation:)
      @viewer = viewer
      @organisation = organisation
    end

    # The lookup a Personal Access Token may open, or nil (S3b E1): only for an organisation
    # whose every project the token reaches (PersonalAccessToken::Reach, nil = all projects).
    # The directory and the last contact read across the whole organisation, and a token
    # limited to some projects was meant to keep its holder to those. A token limited to
    # some projects, an organisation outside the token (an inactive membership included,
    # PersonalAccessToken#organisation_scopes), a missing one and a malformed id all answer
    # nil, so a caller tells none of them apart.
    def self.for_token(reach:, viewer:, organisation_id:)
      id = Lalabase::Uuid.dashed(organisation_id)
      return nil if id.nil? || !reach.project_ids_for(id).nil?

      organisation = Organisation.find_by(id: id)
      new(viewer: viewer, organisation: organisation) if organisation
    end

    # The one rights question of the directory, the people page's own.
    def allowed?
      PersonPolicy.view_allowed?(@viewer, @organisation)
    end

    # The entries matching query and kind, sorted by name, each with its last contact.
    def find(limit:, query: nil, kind: nil, offset: 0)
      check_allowed!
      entries = directory(query: query, kind: kind_of(kind)).entries
      Page.new(entries: entries.drop(offset).first(limit), total: entries.size)
    end

    # The entry an id names, with its last contact, or nil.
    def entry(id)
      check_allowed!
      people = directory
      found = Listing.new(directory: people).entry(id)
      found&.tap { |entry| entry.last_contact = people.last_contacts_for([entry]).first }
    end

    # This organisation for a list over several, read through one directory (Listing).
    # Nothing is read before the listing is asked.
    def listing(query: nil)
      check_allowed!
      Listing.new(directory: directory(query: query))
    end

    def self.key_for(entry)
      Meetings::ParticipantLinkChoice.value_for(entry)
    end

    # One row of a list: who it is and what they do, no contact details. A member's name is
    # the account's (Entry#plain_name), as on the people page.
    def self.row(entry)
      person = entry.person
      {
        id: key_for(entry),
        name: entry.plain_name,
        kind: entry.member? ? 'member' : 'contact',
        function: person&.function,
        department: person&.department,
        company: person&.company,
        last_contact: last_contact(entry.last_contact)
      }
    end

    # The card of one person: the row plus how to reach them. A member's email is the one
    # they show to others (User#shown_email, nil when none), as on the people page; phone,
    # details and notes come from the row. The notes
    # as stored, nil when blank or when a member has no row. kind_names: a detail without
    # a label is named by the name of its kind in the reader's language, as the people
    # page names it (a page that shows the card, People::MergedCard); without it by the
    # kind itself, the word a program reads (REST, MCP, the assistant).
    def self.card(entry, notes: false, kind_names: false)
      person = entry.person
      card = row(entry).merge(
        salutation: person&.salutation,
        email: entry.member? ? entry.user.shown_email : person&.email,
        phone: person&.phone,
        additional_details: details(person, kind_names: kind_names)
      )
      notes ? card.merge(notes: person&.notes.presence) : card
    end

    # The additional details as label and value. A detail without a label is named by its
    # kind (see .card).
    def self.details(person, kind_names:)
      list = person&.additional_details
      return [] unless list.is_a?(Array)

      list.map do |raw|
        detail = PersonDetail.new(raw)
        unnamed = kind_names ? PersonDetail.kind_name(detail.kind) : detail.kind
        { label: detail.label.presence || unnamed, value: detail.value }
      end
    end

    # The last contact as date and kind only (S3 E3): no meeting title, no ticket number, so
    # an answer names nothing it does not cite. The date in the app's time zone.
    def self.last_contact(last)
      return nil if last.nil?

      { on: last.at.in_time_zone.to_date.iso8601, kind: last.kind.to_s }
    end

    private_class_method :details, :last_contact

    private

    def check_allowed!
      raise Refused unless allowed?
    end

    # Blank is "all"; anything else must be one of KINDS.
    def kind_of(value)
      kind = value.presence&.to_s || 'all'
      raise InvalidArgument, KIND_ERROR unless KINDS.include?(kind)

      kind
    end

    def directory(query: nil, kind: 'all')
      People::Directory.new(viewer: @viewer, organisation: @organisation, query: query, kind: kind)
    end
  end
end
