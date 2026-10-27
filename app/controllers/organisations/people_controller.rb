# frozen_string_literal: true

# The people directory of an organisation (Person): members with their extra
# details and contacts without a login, kept by consultant and customer
# together. One page with a lane, the shape of "Alle Meetings"
# (MeetingsOverviewController): the list on the left, the person or the form in
# the lane frame on the right. The address carries the lane state:
# ?person_id= for a person, ?member_id= for a member who has no row of their
# own yet (name and email from the account, "Angaben ergänzen"), ?new=person
# for the form.
#
# show, new and edit answer the lane frame (a row click, the "+", "Bearbeiten");
# a full visit of them lands on the index with the same lane state. The index
# answers a lane frame request with the lane alone (the restorer on Back, a
# redirect inside the frame).
#
# Writes go through Actors::SavePerson / DestroyPerson and leave the frame
# (_top): a save redraws the list and the lane on the index with the saved
# person open, a refused save renders the index with the form again (422).
#
# Rights: PersonPolicy (view_people / manage_people, account admins without a
# row). A denial answers 403 here, not the app's redirect: the page and its
# frame have nothing to show, and a redirect inside the lane frame loops.
module Organisations
  class PeopleController < Organisations::BaseController
    include ViewportSwitchable

    DETAIL_FRAME_ID = 'person_display_frame'
    LIST_FRAME_ID = 'people_results'
    NEW_STATE = 'person'
    # The list state the lane's forms and links carry, so a save keeps it.
    LIST_PARAMS = %w[q kind sort].freeze
    # The meetings the lane shows before "Alle N anzeigen".
    MEETINGS_SHOWN = 3

    rescue_from Pundit::NotAuthorizedError, with: :render_forbidden

    # Every action: the lane frames (show, member, new, edit) render the phone
    # layout too, and only the address knows which one.
    before_action :set_viewport_mode
    before_action :set_person, only: %i[show edit update destroy]

    def index
      authorize Person
      @people = policy_scope(Person)
      return render_lane_frame if lane_frame_request?

      member_row = member_with_row
      return redirect_to(index_path(person_id: member_row.id)) if member_row

      load_list
      @lane_person = selected_person
      @lane_member = selected_member if @lane_person.nil?
      @form_person = new_person if @lane_person.nil? && @lane_member.nil? && new_person_requested?
    end

    # A member without a row of their own, in the lane. Only a member the
    # reader may see on the members page (People::Directory), else 404; a
    # member who has a row opens that row.
    def member
      authorize Person, :index?
      entry = directory.member_entry(params[:user_id])
      raise ActiveRecord::RecordNotFound unless entry
      return redirect_to(index_path(**member_lane(entry))) unless turbo_frame_request?
      return render_frame(:detail, person: entry.person) if entry.person

      render_frame(:member, member: entry.user)
    end

    def show
      authorize @person
      return redirect_to(index_path(person_id: @person.id)) unless turbo_frame_request?

      render_frame(:detail, person: @person)
    end

    def new
      @person = new_person
      authorize @person
      return redirect_to(index_path(new: NEW_STATE)) unless turbo_frame_request?

      render_frame(:form, person: @person)
    end

    def edit
      authorize @person
      return redirect_to(index_path(person_id: @person.id)) unless turbo_frame_request?

      render_frame(:form, person: @person)
    end

    def create
      authorize Person
      save_person(id: nil, flash_key: 'controllers.people.create.success')
    end

    def update
      authorize @person
      save_person(id: @person.id, flash_key: 'controllers.people.update.success')
    end

    def destroy
      authorize @person
      result = Actors::DestroyPerson.call(person: @person, current_user: current_user)
      if result.success?
        redirect_to index_path, status: :see_other, notice: t('controllers.people.destroy.success')
      else
        redirect_to index_path(person_id: @person.id), status: :see_other, alert: result.errors.to_sentence
      end
    end

    private

    # The right first (403 without it, before anything is looked up), then
    # through the policy scope: a person of another organisation, or one linked
    # to a member the reader may not see, is no person at all (404).
    def set_person
      authorize Person, :index?
      @person = policy_scope(Person).find(params[:id])
    end

    def save_person(id:, flash_key:)
      result = Actors::SavePerson.call(organisation: current_organisation, params: person_params,
                                       current_user: current_user, id: id)
      if result.success?
        redirect_to index_path(person_id: result.resource.id), status: :see_other, notice: t(flash_key)
      else
        render_refused_save(result, id)
      end
    end

    # The index again, with the form open in the lane and the reason above it.
    # A stale save shows the CURRENT values: the other side's change stays, and
    # the reader sees what they would overwrite.
    def render_refused_save(result, id)
      @form_person = refused_form_person(result, id)
      @form_message = result.code == :stale_object ? t('controllers.people.update.stale') : result.errors.to_sentence
      load_list
      set_viewport_mode
      render :index, status: :unprocessable_content
    end

    def refused_form_person(result, id)
      return policy_scope(Person).find(id) if result.code == :stale_object

      result.resource || new_person
    end

    def person_params
      params.require(:person).permit(*Actors::SavePerson::ATTRIBUTES, :user_id)
    end

    def directory
      @directory ||= People::Directory.new(viewer: current_user, organisation: current_organisation,
                                           query: params[:q], kind: params[:kind], sort: params[:sort])
    end

    def load_list
      @entries = directory.entries
      @counts = directory.counts
    end

    def member_lane(entry)
      entry.person ? { person_id: entry.person.id } : { member_id: entry.user.id }
    end

    # ?member_id= of a member who has a row by now: the row is the address.
    def member_with_row
      id = params[:member_id]
      return unless id.is_a?(String) && id.present? && params[:person_id].blank?

      directory.member_entry(id)&.person
    end

    # ?member_id=: the account of a visible member without a row. A member who
    # has a row is opened through that row (person_id), never twice.
    def selected_member
      id = params[:member_id]
      return unless id.is_a?(String) && id.present?

      entry = directory.member_entry(id)
      entry.user if entry && entry.person.nil?
    end

    # A member row without a person row opens the form with the member chosen
    # (?user_id=). Only a member the reader may link: an active member visible
    # on the members page without a row yet. Anything else is no choice, so the
    # select never names an account the reader may not see. SavePerson checks
    # the choice again on save.
    def new_person
      current_organisation.people.build(user_id: linkable_user_id(params[:user_id]))
    end

    def linkable_user_id(value)
      return unless value.is_a?(String) && value.present?

      visible = policy_scope(Membership).where(organisation: current_organisation, active: true, user_id: value).exists?
      taken = Person.where(organisation: current_organisation, user_id: value).exists?
      value if visible && !taken
    end

    def new_person_requested?
      params[:new] == NEW_STATE && policy(Person).create?
    end

    def selected_person
      id = params[:person_id]
      @people.find_by(id: id) if id.is_a?(String) && id.present?
    end

    def lane_frame_request?
      turbo_frame_request? && request.headers['Turbo-Frame'] == DETAIL_FRAME_ID
    end

    # The lane alone, as a full visit of the same address shows it.
    def render_lane_frame
      person = selected_person
      member = selected_member unless person
      if person
        render_frame(:detail, person: person)
      elsif member
        render_frame(:member, member: member)
      elsif new_person_requested?
        render_frame(:form, person: new_person)
      else
        render_frame(:empty)
      end
    end

    def render_frame(state, person: nil, member: nil, status: :ok)
      render html: helpers.turbo_frame_tag(DETAIL_FRAME_ID) {
        helpers.render(partial: 'organisations/people/lane',
                       locals: { state: state, person: person, member: member, message: nil })
      }, layout: false, status: status
    end

    def render_forbidden
      skip_authorization
      skip_policy_scope
      if turbo_frame_request?
        render html: helpers.turbo_frame_tag(request.headers['Turbo-Frame']) {
          helpers.tag.p(t('shared.errors.not_authorized'), class: 'py-10 text-center text-sm text-muted')
        }, layout: false, status: :forbidden
      else
        render plain: t('shared.errors.not_authorized'), status: :forbidden
      end
    end

    def index_path(**lane)
      organisation_people_path(current_organisation, list_state.merge(lane.stringify_keys).compact_blank)
    end

    # The accounts the reader may see on the members page (MembershipPolicy::
    # Scope), once per request: who created or changed a row is named only
    # when the reader may see them (PeopleHelper#person_actor_name).
    def people_visible_member_ids
      @people_visible_member_ids ||= policy_scope(Membership).where(organisation: current_organisation).pluck(:user_id).to_set
    end
    helper_method :people_visible_member_ids

    # The list state of this request (the address, or the hidden fields of a
    # lane form). Kept to strings: a list state is a word and a search. The
    # phone view rides along (viewport=mobile): without it a refused save or a
    # redirect renders the desktop page, and viewport_controller reloads the
    # original address, losing the reason and the values typed.
    def list_state
      given = request.query_parameters.merge(request.request_parameters)
      state = given.slice(*LIST_PARAMS).select { |_key, value| value.is_a?(String) && value.present? }
      state.delete('sort') unless People::Directory::SORTS.include?(state['sort'])
      state['viewport'] = 'mobile' if given['viewport'] == 'mobile'
      state
    end
    helper_method :list_state
  end
end
