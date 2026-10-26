# frozen_string_literal: true

# app/services/actors/save_person.rb
#
# Creates or updates one row of the people directory (Person). Rights are the
# caller's (PersonPolicy); this actor owns the write:
#
# * the member link: a raw user_id from the form is resolved through the
#   members the writer may see (MembershipPolicy::Scope, active only), never
#   assigned as given. Linking copies the member's name into the row, so the
#   row keeps a name when the link goes (PersonLinkRelease).
# * creator on create, updater on every save;
# * a stale save (lock_version, both sides edit the same row) raises
#   StaleObjectError, which BaseActor maps to code :stale_object; the
#   controller shows the form again with the current values.
#
# Tracking is PersonTrackable's: no personal data, no fanout.
module Actors
  class SavePerson < BaseActor
    ATTRIBUTES = %i[name function department company email phone notes lock_version].freeze

    def initialize(organisation:, params:, current_user:, id: nil)
      super()
      @organisation = organisation
      @params = params.to_h.symbolize_keys
      @current_user = current_user
      @person = find_person(id)
    end

    def record
      @person
    end

    def perform
      raise ActorError.new(I18n.t('controllers.people.not_found'), code: :not_found) if @person.nil?

      check_lock_version
      @person.assign_attributes(@params.slice(*ATTRIBUTES))
      assign_link if @params.key?(:user_id)
      @person.creator ||= @current_user if @person.new_record?
      @person.updater = @current_user
      save_link_safely
    end

    private

    attr_reader :current_user

    # A lock_version that is not a number (a hand-made request) cannot say what
    # the writer saw; Rails would raise on a nil one. Treated as stale.
    def check_lock_version
      return unless @params.key?(:lock_version)
      return if Integer(@params[:lock_version].to_s, exception: false)

      raise ActorError.new(I18n.t('controllers.people.update.stale'), code: :stale_object)
    end

    # Two saves linking the same member at once: the validation passes for
    # both, the unique index refuses the second. A failure, not a crash.
    def save_link_safely
      @person.save!
    rescue ActiveRecord::RecordNotUnique
      raise ActorError.new(I18n.t('controllers.people.link_not_allowed'), code: :validation_failed)
    end

    # Tenant-bound lookup: an id of another organisation is no person at all.
    def find_person(id)
      return @organisation.people.build if id.blank?

      Person.where(organisation: @organisation).find_by(id: id)
    end

    def assign_link
      user_id = @params[:user_id].presence
      return @person.user = nil if user_id.nil?
      return if user_id == @person.user_id

      user = linkable_users.find_by(id: user_id)
      raise ActorError.new(I18n.t('controllers.people.link_not_allowed'), code: :validation_failed) unless user

      @person.user = user
      @person.name = user.display_name
    end

    # The members the writer may link: active, and visible to them on the
    # members page.
    def linkable_users
      member_ids = ActsAsTenant.with_tenant(@organisation) do
        MembershipPolicy::Scope.new(@current_user, Membership).resolve
                               .where(organisation: @organisation, active: true).select(:user_id)
      end
      User.where(id: member_ids)
    end
  end
end
