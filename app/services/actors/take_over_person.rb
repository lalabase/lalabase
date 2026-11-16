# frozen_string_literal: true

# app/services/actors/take_over_person.rb
#
# Takes a contact of one organisation over into another one of the viewer's:
# a copy of the fields they ticked, as an ordinary new row of the target
# (People S0). Nothing links the two rows afterwards, and the target records
# nothing about the source: its history says only "created a person", like any
# other new row (PersonTrackable). The notice "taken over from ..." is the
# controller's flash, for the viewer alone.
#
# Two tenant blocks, one per organisation; nothing is read across tenants:
#
# * source, inside ActsAsTenant.with_tenant(source): People::Lookup#entry, the
#   viewer's own right to read that directory. Only a contact whose row has no
#   account (user_id nil): no member, and no row of a deactivated member
#   either. The directory lists that row as a contact, but duplicates_of drops
#   every entry of the same account, so the duplicate question would stay
#   silent and the copy would double a member of the target. The values of the
#   ticked fields are read here and leave the block as a plain hash.
# * target, inside ActsAsTenant.with_tenant(target): the target comes from the
#   viewer's ACTIVE memberships (never a raw id), is never the source, and
#   PersonPolicy#create? holds there. Then the duplicate check (the target's
#   directory, by normalized name) unless the viewer confirmed it, then
#   Actors::SavePerson writes the row.
#
# Every refusal answers alike (code :not_found, the text of an unknown person):
# an unknown, foreign, unreadable or deleted source, a member, a deactivated
# member's row, a target that is no active membership, the source itself, a
# target without the right to create people, a malformed id. A caller cannot
# tell them apart, so the dialog learns nothing about the other organisation.
# A same-named entry of the target is its own code (:duplicate), with a
# question that names only entries of the target the viewer may read there.
module Actors
  class TakeOverPerson < BaseActor
    # The fields the dialog offers and the server accepts in the ticked list.
    # The name always travels (Person validates it). The values come from the
    # source row, never from the request.
    FIELDS = %w[salutation function department company email phone additional_details notes].freeze
    # Ticked when the dialog opens: everything but the notes (free text about a
    # third person, written for the source organisation's readers).
    DEFAULT_FIELDS = (FIELDS - %w[notes]).freeze
    NOT_FOUND = :not_found
    DUPLICATE = :duplicate

    # The organisations the dialog lists as targets: the viewer's active ones
    # except the source, where they may create people. The same rule the
    # actor applies to the target it gets, asked under each tenant.
    def self.targets_for(viewer:, source:)
      viewer.active_organisations.where.not(id: source.id).order(:name).to_a
            .select { |organisation| creatable_in?(viewer, organisation) }
    end

    # PersonPolicy#create? reads the tenant of the thread, so it is asked inside
    # the organisation's own block.
    def self.creatable_in?(viewer, organisation)
      ActsAsTenant.with_tenant(organisation) { PersonPolicy.new(viewer, Person).create? }
    end

    def initialize(source_organisation:, person_id:, target_organisation_id:, fields:, confirm_duplicate:, current_user:)
      super()
      @source_organisation = source_organisation
      @person_id = person_id
      @target_organisation_id = target_organisation_id
      @fields = ticked(fields)
      @confirm_duplicate = confirm_duplicate == true
      @current_user = current_user
    end

    def record
      @copy
    end

    def perform
      source = read_source
      refuse unless @target && source

      ActsAsTenant.with_tenant(@target) { write_copy(@target, source) }
    end

    private

    attr_reader :current_user

    # SavePerson's row commits when the transaction of BaseActor#call commits,
    # after #perform returned, and PersonTrackable writes its "created"
    # activity in that commit callback. acts_as_tenant overwrites the
    # organisation of a new row with the tenant of the thread, so under the
    # request's tenant (the source) the target's history entry would land in
    # the SOURCE organisation. The whole transaction therefore runs under the
    # target's tenant; the target is resolved here, before it opens. Without
    # a target nothing is written and the tenant stays as it was.
    def with_actor_context(user = nil, &)
      @target = target_organisation
      return super unless @target

      super(user) { ActsAsTenant.with_tenant(@target, &) }
    end

    # Only names of FIELDS, only strings: a list of anything else is nothing ticked.
    def ticked(fields)
      return [] unless fields.is_a?(Array)

      fields.grep(String) & FIELDS
    end

    # One of the viewer's active organisations, never the source.
    def target_organisation
      id = Lalabase::Uuid.dashed(@target_organisation_id) if @target_organisation_id.is_a?(String)
      return if id.nil? || id == @source_organisation.id

      current_user.active_organisations.find_by(id: id)
    end

    # The source row and the values to copy, read with the viewer's right in
    # the source organisation; nil for anything the actor refuses.
    def read_source
      ActsAsTenant.with_tenant(@source_organisation) do
        row = contact_row
        { row: row, values: values_of(row) } if row
      end
    end

    def contact_row
      entry = People::Lookup.new(viewer: current_user, organisation: @source_organisation).entry("person:#{@person_id}")
      row = entry&.person
      row if entry && !entry.member? && row.user_id.nil?
    rescue People::Lookup::Refused, People::Lookup::InvalidArgument
      nil
    end

    def values_of(row)
      values = { name: row.name }
      @fields.each { |field| values[field.to_sym] = row.public_send(field) }
      values[:additional_details] = row.additional_details.map(&:dup) if @fields.include?('additional_details')
      values
    end

    def write_copy(target, source)
      refuse unless self.class.creatable_in?(current_user, target)
      ask_about_duplicates(target, source[:row]) unless @confirm_duplicate

      result = Actors::SavePerson.call(organisation: target, params: source[:values], current_user: current_user)
      raise ActorError.new(result.errors, code: result.code) unless result.success?

      @copy = result.resource
    end

    # The target's own entries with the same normalized name, as the viewer
    # may read them there. The source row is only compared by its loaded
    # attributes (id, normalized_name, user_id); nothing of it is loaded here.
    def ask_about_duplicates(target, row)
      names = People::Directory.new(viewer: current_user, organisation: target).duplicates_of(row).map(&:plain_name)
      return if names.empty?

      raise ActorError.new(I18n.t('controllers.people.takeover.duplicate', names: names.to_sentence,
                                                                           organisation: target.name),
                           code: DUPLICATE)
    end

    def refuse
      raise ActorError.new(I18n.t('controllers.people.not_found'), code: NOT_FOUND)
    end
  end
end
