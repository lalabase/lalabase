# frozen_string_literal: true

require 'rails_helper'

# Bezugs-Sammlung S1 (§5, T-1 and T-2): the reference registry declares two things
# that already have owners elsewhere, and this is what keeps it from becoming a
# FOURTH card that drifts away from the three that exist.
#
# The three it must agree with:
#   * ProjectRag::ContentAreaRegistry::AREA_BY_TYPE  -- AR type -> gating area
#   * Lalabase::Citations::TYPES                     -- citation type -> shape
#   * Lalabase::CitationTargets::MODEL_NAMES         -- citation type -> model
#
# Deliberately a check on the DECLARATION rather than a lookup at runtime: the
# registry has to name its area and its citation type in one place a reader can
# see, and S4 already knows one case where the two maps legitimately differ
# (Document is what a human references, DocumentVersion is where the embedding
# hangs). Hence T-1 is CONDITIONAL -- see below.
RSpec.describe 'Assistant::ReferenceRegistry agrees with the maps that exist', type: :model do
  let(:entries) { Assistant::ReferenceRegistry::ENTRIES }

  # Sanity: an empty registry would make every check below vacuously green.
  it 'has entries to check' do
    expect(entries).not_to be_empty
    expect(Assistant::ReferenceRegistry.types).to include('Ticket', 'Note', 'Document', 'Meeting')
  end

  it 'keys every entry by its own type name' do
    offenders = entries.reject { |type, entry| type == entry.type }

    expect(offenders.keys).to be_empty
  end

  # T-1. The area is the GATE: Tools::Scope#area_reach resolves an entry against
  # AccessCheck::ProjectAccessService.accessible_project_ids for exactly this
  # area, and that service spells the area into ProjectPermission's enum
  # accessors ("#{area}_accesses"). So the set of areas that may be declared here
  # is ProjectPermission.access_areas and nothing wider: an area outside it is a
  # NoMethodError in the job for every non-admin member (admins short-circuit
  # before the accessor), not a silent refusal. ⚠️ In particular NOT
  # :time_sessions, whatever ProjectPolicy#area_access? accepts for it -- time
  # rights live in TimeSessions::ViewingScope, not on the permission row.
  it 'declares an area accessible_project_ids understands' do
    known = ProjectPermission.access_areas
    offenders = entries.reject { |_type, entry| known.include?(entry.area) }

    expect(offenders.keys).to be_empty, <<~MSG
      These reference types declare an area AccessCheck::ProjectAccessService.accessible_project_ids does not know:
        #{offenders.map { |type, entry| "#{type} -> #{entry.area}" }.join("\n  ")}
      Known: #{known.sort.join(', ')}
    MSG
  end

  # T-1, second half. ⚠️ CONDITIONAL, and the condition is the point: the area has
  # to MATCH AREA_BY_TYPE wherever the type appears there, so the assistant cannot
  # gate a type more loosely than the retriever does. Where the type does NOT
  # appear there, no claim is made -- S4 references `Document` while AREA_BY_TYPE
  # knows only `DocumentVersion`, and an unconditional check written in S1 would
  # be wrong by S4.
  it 'matches ContentAreaRegistry wherever the type is registered there' do
    offenders = entries.filter_map do |type, entry|
      known = Lalabase::ProjectRag::ContentAreaRegistry.area_for(type)
      next if known.nil? || known == entry.area

      "#{type}: registry says #{entry.area}, AREA_BY_TYPE says #{known}"
    end

    expect(offenders).to be_empty, offenders.join("\n")
  end

  # And the counter-example to the conditional: at least one entry must actually
  # BE in AREA_BY_TYPE, or the check above is satisfied by a registry whose types
  # are all unknown to the retriever.
  it 'has at least one entry the conditional check actually applies to' do
    covered = entries.keys.select { |type| Lalabase::ProjectRag::ContentAreaRegistry.area_for(type) }

    expect(covered).not_to be_empty
  end

  # T-2. The citation type is what gives an entry its icon and its wording. It is
  # declared here and checked against the map that already owns the reverse
  # direction, instead of a fourth map being written: MODEL_NAMES[citation_type]
  # must name this very type.
  it 'declares a citation type CitationTargets maps back to the same model' do
    offenders = entries.filter_map do |type, entry|
      mapped = Lalabase::CitationTargets::MODEL_NAMES[entry.citation_type]
      next if mapped == type

      "#{type}: citation_type #{entry.citation_type.inspect} maps back to #{mapped.inspect}"
    end

    expect(offenders).to be_empty, <<~MSG
      #{offenders.join("\n")}

      Do not add a fourth map. Declare a citation_type that CitationTargets::MODEL_NAMES
      already resolves to this model, or fix the entry.
    MSG
  end

  it 'declares a citation type Citations knows at all' do
    offenders = entries.reject { |_type, entry| Lalabase::Citations::TYPES.include?(entry.citation_type) }

    expect(offenders.keys).to be_empty
  end

  # ⚠️ S2 gave every registered type TWO locale families, and nothing pinned them.
  # Both are keyed by `citation_type`:
  #   * jobs.ai_chat.reference_items.<citation_type>
  #     (ChatResponseJob#reference_line -- this text goes into the SYSTEM PROMPT)
  #   * views.organisations.assistant_panels.reference.types.<citation_type>
  #     (ReferenceChipComponent#summary_label -- this text goes on screen)
  #
  # config.i18n.raise_on_missing_translations is commented out in test.rb AND in
  # development.rb. So a missing key is an error nowhere: S3 adding 'Meeting' to
  # ENTRIES would write "Translation missing: de.jobs.ai_chat.reference_items.meeting"
  # into the prompt and onto the panel, and every spec would stay green.
  #
  # Same answer as Chats::ScopeProjectCleanup#ensure_registry_is_mapped!, one layer
  # up: a registry that grows must not be able to outgrow what its readers can say.
  #
  # ⚠️ fallback: false, and it is not decoration. i18n.rb sets fallbacks = [:de], and
  # BOTH I18n.t and I18n.exists? walk that chain -- so a key missing only in EN
  # resolves through DE and the check passes. Measured: the first version of this
  # cell used I18n.exists? and its mutation probe stayed green. Same reasoning the
  # house already wrote down in spec/locales/ai_chat_keys_spec.rb.
  it 'has a prompt sentence for every registered type, in both languages' do
    offenders = %i[de en].flat_map do |locale|
      entries.values.filter_map do |entry|
        key = "jobs.ai_chat.reference_items.#{entry.citation_type}"
        line = I18n.t(key, locale: locale, fallback: false, title: 't', project: 'p', id: 'i')
        "#{locale}: #{key}" if line.blank? || line.downcase.include?('translation missing')
      end
    end

    expect(offenders).to be_empty, <<~MSG
      Missing prompt sentence for a registered reference type:
      #{offenders.join("\n")}

      A new entry in ENTRIES needs its line in config/locales/services.{de,en}.yml.
    MSG
  end

  # ⚠️ Both plural forms, and asked by TRANSLATING rather than by asking whether the
  # key is there. `one` is unreachable today with a single registered type, and the
  # locale file says so in its own comment -- but a missing `one` does not fall back
  # to `other`, it raises I18n::InvalidPluralizationData the first time a mixed
  # collection holds a group of exactly one. That is S3, in a panel render.
  it 'has both plural forms of the chip group label for every registered type' do
    offenders = %i[de en].flat_map do |locale|
      entries.values.flat_map do |entry|
        base = "views.organisations.assistant_panels.reference.types.#{entry.citation_type}"
        [1, 2].filter_map do |count|
          label = I18n.t(base, count: count, locale: locale, fallback: false)
          next if label.is_a?(String) && label.present? && !label.downcase.include?('translation missing')

          "#{locale}: #{base} for count #{count}"
        rescue I18n::InvalidPluralizationData
          "#{locale}: #{base} has no form for count #{count}"
        end
      end
    end

    expect(offenders).to be_empty, <<~MSG
      Missing chip group label for a registered reference type:
      #{offenders.join("\n")}

      A new entry in ENTRIES needs BOTH plural forms in
      config/locales/views/assistent.{de,en}.yml.
    MSG
  end

  # Both lambdas are contracts, not decoration: Tools::Scope calls `reachable` with
  # three positional arguments and every surface calls `title` with two. An entry
  # that takes a different shape blows up at render time, in a job, in production.
  it 'declares lambdas of the arity the callers use' do
    expect(entries.values.map { |entry| entry.reachable.arity }).to all(eq(3))
    expect(entries.values.map { |entry| entry.title.arity }).to all(eq(2))
  end

  # The key vocabulary of §7.1 is ONE value, and this is the round trip that says
  # so. ⚠️ parse_key must never constantize: an unregistered type is refused by
  # LOOKUP, which is also why "Object" and "Kernel" answer nil here rather than
  # resolving to real Ruby constants.
  describe 'the composite key' do
    let(:uuid) { SecureRandom.uuid }

    it 'round-trips a registered type' do
      key = Assistant::ReferenceRegistry.key_for(type: 'Ticket', id: uuid)

      expect(key).to eq("Ticket:#{uuid}")
      expect(Assistant::ReferenceRegistry.parse_key(key)).to eq(type: 'Ticket', id: uuid)
    end

    it 'refuses a type that is a real constant but not a registered reference' do
      expect(Assistant::ReferenceRegistry.parse_key("Object:#{uuid}")).to be_nil
      expect(Assistant::ReferenceRegistry.parse_key("Project:#{uuid}")).to be_nil
      expect(Assistant::ReferenceRegistry.parse_key("MeetingAnalysis:#{uuid}")).to be_nil
    end

    it 'refuses an id that is not a UUID, a missing separator and an empty key' do
      expect(Assistant::ReferenceRegistry.parse_key('Ticket:nope')).to be_nil
      expect(Assistant::ReferenceRegistry.parse_key('Ticket')).to be_nil
      expect(Assistant::ReferenceRegistry.parse_key('')).to be_nil
      expect(Assistant::ReferenceRegistry.parse_key(nil)).to be_nil
    end

    # The stored form and the key are two spellings of one identity, and this is
    # the seam between them. A stored entry with an extra key is not a pair.
    # Postgres reads "ABC-..." and "abc-..." as the same uuid; a Hash lookup does
    # not. The key is compared as a string (against data-reference-keys, against
    # the stored pair, against record.id), so it has ONE spelling: the one
    # record.id comes back in. Found in review: a DELETE with an upper-case id
    # answered success and removed nothing.
    it 'canonicalises the id to the lowercase dashed spelling record.id uses' do
      expect(Assistant::ReferenceRegistry.parse_key("Ticket:#{uuid.upcase}")).to eq(type: 'Ticket', id: uuid)
    end

    it 'refuses the 32-hex spelling rather than re-dashing it' do
      expect(Assistant::ReferenceRegistry.parse_key("Ticket:#{uuid.delete('-')}")).to be_nil
    end

    # A namespaced type carries its own colons ("Foo::Bar"); the id never does, so
    # the LAST separator is the one that splits. With partition instead of
    # rpartition such a type would be looked up as "Foo" and fail closed for good,
    # while the panel composes exactly that key from the page's marker.
    it 'splits at the last separator, so a namespaced type stays whole' do
      ticket_entry = Assistant::ReferenceRegistry::ENTRIES.fetch('Ticket')
      stub_const('Assistant::ReferenceRegistry::ENTRIES',
                 Assistant::ReferenceRegistry::ENTRIES.merge('Foo::Bar' => ticket_entry))

      expect(Assistant::ReferenceRegistry.parse_key("Foo::Bar:#{uuid}")).to eq(type: 'Foo::Bar', id: uuid)
    end

    it 'reads a stored pair and refuses anything that is not exactly one' do
      expect(Assistant::ReferenceRegistry.entry_from('type' => 'Ticket', 'id' => uuid))
        .to eq(type: 'Ticket', id: uuid)
      expect(Assistant::ReferenceRegistry.entry_from('type' => 'Ticket', 'id' => uuid, 'note' => 'x')).to be_nil
      expect(Assistant::ReferenceRegistry.entry_from('type' => 'Ticket')).to be_nil
      expect(Assistant::ReferenceRegistry.entry_from('Ticket')).to be_nil
      expect(Assistant::ReferenceRegistry.entry_from(nil)).to be_nil
    end

    it 'writes the stored form with string keys, which is what jsonb reads back' do
      expect(Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: uuid))
        .to eq('type' => 'Ticket', 'id' => uuid)
    end
  end
end
