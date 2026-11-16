# frozen_string_literal: true

# Entry point: resolve
module ObjectLinks
  # What a reader may see of the objects some links name: a label per readable target, and
  # nothing for the rest. One instance per reader and organisation per request
  # (Current.object_link_targets), so every rich text of a page shares what was loaded.
  #
  # The one way this feature can disclose data is a title or a name next to an address, so:
  #
  #   * every type loads through its policy scope (TicketPolicy::Scope, MeetingPolicy::Scope,
  #     NotePolicy::Scope, DocumentPolicy::Scope) inside the organisation, never by a bare
  #     find. People go through People::Directory, the reach of the people page itself
  #     (PersonPolicy's right, and a member only where the members page shows them);
  #   * an address that names a project must name the target's own project;
  #   * not found, not readable and not this organisation's all answer the same: no label.
  #
  # Loaded per type in one query for all ids not seen yet; the reach of a type (the policy
  # scope's project ids) is resolved once per instance. A list that renders many rich texts
  # hands all of them in first (ObjectLinks::Chips.prefetch), then each text costs nothing.
  class Targets
    include OneLineText

    # E1: the chip's label is cut here; the title attribute carries FULL_LABEL_MAX.
    LABEL_MAX = 40
    FULL_LABEL_MAX = 300

    # label: what the chip shows; full_label: its title attribute.
    Target = Data.define(:type, :label, :full_label)

    # What was found for one id, with the project it lives in (nil for people).
    Found = Data.define(:target, :project_id)

    PROJECT_TYPES = {
      ticket: Ticket,
      meeting: Meeting,
      note: Note,
      document: Document
    }.freeze

    # A label needs no transcript, extracted text or summary. Keep those large fields
    # out of the result even when a page batches many links into a single query.
    LABEL_COLUMNS = {
      # CustomAttributable's after_initialize reads this metadata even for a label.
      ticket: %i[id project_id number title custom_attributes],
      meeting: %i[id project_id occurred_at title],
      note: %i[id project_id title]
    }.freeze

    def initialize(viewer:, organisation:)
      @viewer = viewer
      @organisation = organisation
      @found = Hash.new { |hash, type| hash[type] = {} }
      @scopes = {}
    end

    # { ref => Target } for the refs the reader may see a label of.
    def resolve(refs)
      load(refs)
      refs.uniq.each_with_object({}) do |ref, result|
        found = @found[ref.type][ref.id]
        next unless found
        next if ref.project_id && ref.project_id != found.project_id

        result[ref] = found.target
      end
    end

    # Loads what is not loaded yet, without answering: for a list before its texts render.
    def load(refs)
      refs.group_by(&:type).each do |type, of_type|
        missing = of_type.map(&:id).uniq.reject { |id| @found[type].key?(id) }
        next if missing.empty?

        missing.each { |id| @found[type][id] = nil }
        load_type(type, missing)
      end
    end

    private

    attr_reader :viewer, :organisation

    def load_type(type, ids)
      case type
      when :person then load_people(type, ids) { |id| directory.person_entry(id) }
      when :member then load_people(type, ids) { |id| directory.member_entry(id) }
      when :document then load_documents(ids)
      else load_records(type, ids)
      end
    end

    def load_records(type, ids)
      relation = scope_for(type).where(id: ids).select(*LABEL_COLUMNS.fetch(type))
      relation.each do |record|
        @found[type][record.id] = Found.new(target: target_for(type, record), project_id: record.project_id)
      end
    end

    # A document's title belongs to its current version. Read just that title through
    # the tenant-scoped association; the left join keeps documents without a version.
    def load_documents(ids)
      scope_for(:document).where(id: ids).left_joins(:current_version)
                          .pluck(:id, :project_id, DocumentVersion.arel_table[:title]).each do |id, project_id, title|
        @found[:document][id] = Found.new(target: titled(:document, title), project_id: project_id)
      end
    end

    # The policy scope of a type, inside this organisation, once per instance: resolving it
    # reads the reader's reach (role, permissions), which does not change within a request.
    def scope_for(type)
      @scopes[type] ||= Pundit.policy_scope!(viewer, PROJECT_TYPES.fetch(type)).where(organisation_id: organisation.id)
    end

    def target_for(type, record)
      # Ticket and Meeting own their one-line form ("#42 Title", "date · title").
      if type.in?(%i[ticket meeting])
        build(type, record.one_line_title(max: LABEL_MAX), record.one_line_title(max: FULL_LABEL_MAX))
      else
        titled(type, record.title)
      end
    end

    # Kept under the type the address ASKED for; the chip shows what the entry IS (a person
    # row of an active member is that member, named the way the reader spells names).
    def load_people(asked, ids)
      ids.each do |id|
        entry = yield(id)
        next unless entry

        target = if entry.member?
                   titled(:member, entry.user.display_name(mode: name_mode))
                 else
                   titled(:person, entry.person.name)
                 end
        @found[asked][id] = Found.new(target: target, project_id: nil)
      end
    end

    def titled(type, text)
      text = I18n.t('views.object_links.untitled') if text.blank?
      build(type, one_line(text, max: LABEL_MAX), one_line(text, max: FULL_LABEL_MAX))
    end

    def build(type, label, full_label)
      Target.new(type: type, label: label, full_label: full_label)
    end

    # The people page's own reach, loaded once (People::Directory reads the whole directory
    # of the organisation, sized for a few hundred rows; it checks PersonPolicy's right).
    def directory
      @directory ||= People::Directory.new(viewer: viewer, organisation: organisation)
    end

    def name_mode
      viewer.preference_store.name_display_mode
    end
  end
end
