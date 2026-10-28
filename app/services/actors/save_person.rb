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
# * the fields the account owns: a row linked to an ACTIVE member takes name,
#   email and its link from the account, as the form shows them (locked, not
#   sent). A hand-made request does not write them either (ACCOUNT_FIELDS),
#   and a row created for a member takes no email of its own. A DEACTIVATED
#   member's row keeps only its link (LINK_FIELDS): no other member, no
#   contact, until the member is removed.
# * creator on create, updater on every save;
# * a stale save (lock_version, both sides edit the same row) raises
#   StaleObjectError, which BaseActor maps to code :stale_object; the
#   controller shows the form again with the current values.
#
# Tracking is PersonTrackable's: no personal data, no fanout.
module Actors
  class SavePerson < BaseActor
    ATTRIBUTES = %i[name salutation function department company email phone notes lock_version].freeze
    # What the account of an active member owns on its row.
    ACCOUNT_FIELDS = %i[name email user_id].freeze
    # What stays while the member is only deactivated: the row's own name and
    # email are the ones shown then, so they stay editable.
    LINK_FIELDS = %i[user_id].freeze
    # lock_version is an integer column (4 bytes).
    LOCK_VERSION_RANGE = (0..((2**31) - 1))

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
      drop_account_fields
      @params = @params.except(:email) if @person.new_record? && @params[:user_id].present?
      attributes = @params.slice(*ATTRIBUTES)
      attributes.delete(:lock_version) if @person.new_record?
      @person.assign_attributes(attributes)
      assign_link if @params.key?(:user_id)
      @person.creator ||= @current_user if @person.new_record?
      @person.updater = @current_user
      save_link_safely
    end

    private

    attr_reader :current_user

    # On an update, a lock_version that is not a number the column can hold (a
    # hand-made request) cannot say what the writer saw; Rails would raise on
    # it. Treated as stale. A new row has none to compare.
    def check_lock_version
      return if @person.nil? || @person.new_record? || !@params.key?(:lock_version)
      return if LOCK_VERSION_RANGE.cover?(Integer(@params[:lock_version].to_s, exception: false))

      raise ActorError.new(I18n.t('controllers.people.update.stale'), code: :stale_object)
    end

    # Two saves linking the same member at once: the validation passes for
    # both, the unique index refuses the second. A failure, not a crash.
    def save_link_safely
      @person.save!
    rescue ActiveRecord::RecordNotUnique
      @person.errors.add(:user_id, :taken)
      raise ActorError.new(I18n.t('controllers.people.link_not_allowed'), code: :validation_failed)
    end

    # A saved row with a membership behind its link keeps that link; an active
    # member's account also owns name and email (Person#stored_membership).
    def drop_account_fields
      membership = @person.stored_membership
      return unless membership

      @params = @params.except(*(membership.active? ? ACCOUNT_FIELDS : LINK_FIELDS))
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
