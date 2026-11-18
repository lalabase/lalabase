# frozen_string_literal: true

# The card of one person of the people list above the organisations (GET /people, the
# lane of AllPeopleController): what every organisation knows about them, side by side.
#
# Entry point: call
module People
  # * One source per organisation the list shows the person in, in the list's order
  #   (People::AcrossOrganisations#shown_at: the rule of who is one person stays there).
  #   Every source is read under the tenant of its organisation, through
  #   People::Lookup.card(entry, notes: true, kind_names: true), the one field selection
  #   of a card: a detail without a label is named as the people page names it.
  # * A reference is not a right: a source the viewer may not read is not handed to this
  #   object at all, so it contributes no value, no note and no name of an organisation.
  #   An address that names nothing the viewer can see answers nil, whatever the reason.
  # * Per field every distinct value with the sources it comes from. Two values are one
  #   when they are equal by the rule of their field (#compared): a phone number without
  #   any whitespace, an email also without its case, anything else with its word breaks
  #   (more spaces, or spaces at the ends, are none). A field has ONE rule (#rule_of),
  #   also where the organisations gave a label different kinds. The card shows the value
  #   as the first source wrote it, with that source's kind. A value some sources lack is
  #   listed last, without a text: a missing value is a difference too, or the reader
  #   could not tell that an organisation does not know the mobile number.
  # * The right to write is asked here, under the tenant (PersonPolicy reads the tenant
  #   of the thread), and leaves as the entry the form would edit. How that
  #   organisation's people page names the form in its address is the page's own
  #   (AllPeopleHelper#all_people_edit_path). Nothing to edit without the right, and
  #   nothing at the name and the email of a member: those belong to the account
  #   (Actors::SavePerson::ACCOUNT_FIELDS).
  # * Plain values leave: strings, ids, flags. No Person, so the view, which runs without
  #   a tenant, has nothing to load more from. The one record is Card#avatar_user, a
  #   member's account for the picture: User carries no tenant.
  # * The notes are free text about a third person. They go to this card and nowhere
  #   else: the card is no tool, and nothing here is sent to an AI provider.
  class MergedCard
    # The fields of a row, in the order of the form. The additional details follow, each
    # under its label, in the order they first appear among the sources.
    FIXED_FIELDS = %i[name salutation function department company email phone].freeze
    # The fixed fields that are of a kind of PersonDetail: compared and shown by its rule.
    # The others are text.
    FIXED_KINDS = { email: 'email', phone: 'phone' }.freeze
    # The kinds with a rule of their own for the comparison, the widest first (#rule_of).
    COMPARED_KINDS = %w[email phone].freeze
    # What the account of a member owns (Actors::SavePerson's list, the fields of it the
    # card shows): no source of kind member offers to edit them.
    ACCOUNT_FIELDS = (Actors::SavePerson::ACCOUNT_FIELDS & FIXED_FIELDS).freeze
    SEPARATOR = ':'

    # address: "<organisation id>:<entry address>" (.address_of) of the first source, the
    # one address a link to this card uses. merge_id: the viewer's merge that joined sources of this
    # person, nil without one. last_contact: { on:, kind:, organisation_id:,
    # organisation_name: } of the newest among the sources, or nil.
    Card = Data.define(:address, :name, :kind, :avatar_user, :fields, :sources, :last_contact, :merge_id)

    # key: one of FIXED_FIELDS, or "detail:<label>" for an additional detail. label: nil
    # for a fixed field (the page names it), the label of a detail as first written.
    # differs: the sources have different sets of values, including a missing value.
    Field = Data.define(:key, :label, :values, :differs)

    # text: the value as the first of its sources wrote it; nil for the entry of the
    # sources that have no value for the field. kind: the kind of PersonDetail that first
    # source gave it (FIXED_KINDS for a fixed field), nil for text and for the entry
    # without a value.
    Value = Data.define(:text, :kind, :sources)

    # edit: what the form of that organisation would edit, as the source's lane names it
    # ({ person_id: } for a row, { member_id: } for a member without one, whose form adds
    # the row), nil when the viewer may not write there or the field belongs to the account.
    ValueSource = Data.define(:organisation_id, :edit)

    # address: the entry's ("person:<uuid>", "member:<uuid>"). lane: what opens the entry
    # on that organisation's people page. edit: as ValueSource#edit, nil where the viewer
    # may only read. takeover: the id of the row when it is a contact without an account
    # and the viewer has somewhere to take it. detachable: Actors::SplitPerson can take
    # this source out alone and keep the rest as shown
    # (People::AcrossOrganisations#shown_at; with fewer than three parts, taking one out
    # is dissolving the merge).
    Source = Data.define(:organisation_id, :organisation_name, :address, :kind, :name, :lane,
                         :edit, :notes, :takeover, :detachable)

    # One source while the card is built: never handed out.
    Read = Struct.new(:organisation_id, :organisation_name, :card, :member, :account, :lane, :edit, :takeover, :detachable)
    private_constant :Read

    # How a card names one of its sources: "<organisation id>:<entry address>" (the lane
    # state ?card=, the source a merge lets go of in Actors::SplitPerson).
    def self.address_of(organisation_id, entry_address)
      [organisation_id, entry_address].join(SEPARATOR)
    end

    # The organisation id (dashed) and the entry address an address of .address_of names,
    # or nil for anything of another shape.
    def self.parse_address(address)
      return unless address.is_a?(String)

      organisation_id, id = address.split(SEPARATOR, 2)
      organisation_id = Lalabase::Uuid.dashed(organisation_id.to_s)
      [organisation_id, id] if organisation_id && id.present?
    end

    def self.call(viewer:, address:, across: nil)
      new(viewer: viewer, address: address, across: across).call
    end

    # across: the read of the list of the same request, so the page and its card share the
    # one directory per organisation. Without it the card reads for itself.
    def initialize(viewer:, address:, across: nil)
      @viewer = viewer
      @address = address
      @across = across || People::AcrossOrganisations.new(viewer: viewer)
    end

    def call
      organisation_id, id = self.class.parse_address(@address)
      return unless organisation_id

      shown = @across.shown_at(organisation_id, id) { |organisation, entry, detachable| read(organisation, entry, detachable) }
      card_of(shown) if shown
    end

    private

    # Everything the card shows of one source. Runs under the tenant of the organisation.
    def read(organisation, entry, detachable)
      person = entry.person
      lane = person ? { person_id: person.id } : { member_id: entry.user.id }
      writable = person ? PersonPolicy.new(@viewer, person).update? : PersonPolicy.new(@viewer, Person).create?
      Read.new(organisation_id: organisation.id, organisation_name: organisation.name,
               card: People::Lookup.card(entry, notes: true, kind_names: true), member: entry.member?,
               account: (entry.user if entry.member?), lane: lane, edit: (lane if writable),
               takeover: takeover_of(organisation, person), detachable: detachable)
    end

    # The row a takeover would copy: only a contact whose row carries no account (not a
    # member, not the row a deactivated member left), and only with a target. The
    # organisations a copy may go to are asked once per card, not once per source.
    def takeover_of(organisation, person)
      return unless person && person.user_id.nil?

      @targets ||= Actors::TakeOverPerson.target_ids_for(viewer: @viewer)
      person.id if @targets.any? { |id| id != organisation.id }
    end

    def card_of(shown)
      reads = shown.sources
      first = reads.first
      Card.new(address: self.class.address_of(first.organisation_id, first.card[:id]), name: first.card[:name],
               kind: first.card[:kind], avatar_user: first.account, merge_id: shown.merge_id,
               fields: fields_of(reads).freeze, last_contact: last_contact_of(reads),
               sources: reads.map { |one| source_of(one) }.freeze)
    end

    def source_of(read)
      Source.new(organisation_id: read.organisation_id, organisation_name: read.organisation_name,
                 address: read.card[:id], kind: read.card[:kind], name: read.card[:name], lane: read.lane,
                 edit: read.edit, notes: read.card[:notes], takeover: read.takeover, detachable: read.detachable)
    end

    def last_contact_of(reads)
      newest = reads.select { |read| read.card[:last_contact] }.max_by { |read| read.card[:last_contact][:on] }
      newest && newest.card[:last_contact].merge(organisation_id: newest.organisation_id, organisation_name: newest.organisation_name)
    end

    # The fixed fields, then the additional details by label. A field no source has a
    # value for is no line of the card.
    def fields_of(reads)
      fixed = FIXED_FIELDS.map { |key| field_of(key, nil, reads) { |read| [[read.card[key], FIXED_KINDS[key]]] } }
      (fixed + detail_fields(reads)).compact
    end

    def detail_fields(reads)
      labels = reads.flat_map { |read| read.card[:additional_details] }
                    .each_with_object({}) { |detail, found| found[label_key(detail[:label])] ||= detail[:label] }
      labels.map do |key, label|
        field_of("detail:#{key}", label, reads) do |read|
          read.card[:additional_details].select { |detail| label_key(detail[:label]) == key }.pluck(:value, :kind)
        end
      end
    end

    # One field: the values of each source (the block's answer, [text, kind] pairs), the
    # equal ones as one.
    def field_of(key, label, reads)
      found = reads.map { |read| [read, yield(read).select { |text, _kind| text.present? }] }
      rule = rule_of(found.flat_map { |_read, entries| entries.map(&:last) })
      values = {}
      lacking = []
      found.each do |read, entries|
        lacking << read if entries.empty?
        entries.each { |text, kind| (values[compared(rule, text)] ||= [text, kind, []]).last << read }
      end
      return if values.empty?

      list = values.values.map { |text, kind, sources| Value.new(text: text, kind: kind, sources: value_sources(key, sources.uniq)) }
      list << Value.new(text: nil, kind: nil, sources: value_sources(key, lacking)) if lacking.any?
      Field.new(key: key, label: label, values: list.freeze, differs: list.any? { |value| value.sources.size != reads.size })
    end

    def value_sources(key, reads)
      reads.map do |read|
        owned_by_account = read.member && ACCOUNT_FIELDS.include?(key)
        ValueSource.new(organisation_id: read.organisation_id, edit: (read.edit unless owned_by_account))
      end.freeze
    end

    # The one rule the values of a field are compared by, whatever kind each source gave
    # its own: an email's as soon as one of them is an email, else a phone number's as
    # soon as one is a phone number, else the words. One organisation may keep "Mobil" as
    # a phone number and another as text; by a rule per entry the same words were two
    # values there, and which source came first decided the answer. The rule holds for
    # every entry of the field, the text ones too, on purpose: a rule per field cannot
    # help reading all sources, so beside an email two texts that differ only in their
    # case are one value. A stricter choice ("only if every entry is of that kind") would
    # bring the two values of one number back as soon as a third source wrote a note.
    def rule_of(kinds)
      COMPARED_KINDS.find { |kind| kinds.include?(kind) }
    end

    # What two values are compared by, by the rule of their field: a phone number
    # without any whitespace ("0171 1" is "01711"), an email also without its case,
    # anything else with its word breaks ("AB C" is not "A BC"), only more spaces and the
    # ends gone.
    def compared(rule, text)
      case rule
      when 'phone' then text.to_s.gsub(/[[:space:]]+/, '')
      when 'email' then text.to_s.gsub(/[[:space:]]+/, '').downcase
      else text.to_s.gsub(/[[:space:]]+/, ' ').strip
      end
    end

    # Two details are the same line of the card when their labels are, whatever their
    # case and spacing: "Mobil" and "mobil" name one thing.
    def label_key(label)
      label.to_s.gsub(/[[:space:]]+/, '').downcase
    end
  end
end
