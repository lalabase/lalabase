# frozen_string_literal: true

# Taking a contact over into another organisation of the viewer (People S0):
# new renders the dialog into its frame (the "···" menu of a card loads it),
# create copies the contact through Actors::TakeOverPerson, which owns every
# rule: the target from the viewer's active memberships, the source read with
# the viewer's right, values from the source row only, the duplicate question.
#
# One refusal, here as in the actor: an unknown or unreadable source, a member
# or a deactivated member's row, a target that is not the viewer's or where
# they may not create people, the source as its own target, and no right to
# read the source directory all answer alike (404, the text of an unknown
# person; Pundit's refusal included). The dialog learns nothing about the other
# organisation. A same-named entry of the target answers the dialog again with
# the question and "Trotzdem anlegen" (422), bound to the target it was asked
# for (confirm_target), so changing the target asks again.
#
# The dialog is a modal in a frame (README_MODAL_PATTERN.md). Its form leaves
# the frame (_top): a copy opens on the target's people page with a one-time
# notice naming the source; that notice is the only trace of the source, and
# only the viewer sees it. Answers to the form go to THIS opening (token).
# The POST keeps the session's organisation (the app's rule for writes); Turbo
# renders the redirect's answer without a page request of its own, so the
# session follows the target on the next full page visit there.
module Organisations
  class PersonTakeoversController < Organisations::BaseController
    MODAL_TOKEN = /\A\h{16}\z/

    rescue_from Pundit::NotAuthorizedError, with: :refuse

    def new
      authorize Person, :index?
      @person = source_row
      @targets = targets
      return refuse if @person.nil? || @targets.empty?
      # The menu link opened in a tab of its own: the card it belongs to.
      return redirect_to(organisation_people_path(current_organisation, person_id: @person.id)) unless turbo_frame_request?

      render_dialog(token: SecureRandom.hex(8))
    end

    def create
      authorize Person, :index?
      result = Actors::TakeOverPerson.call(source_organisation: current_organisation, person_id: person_id.to_s,
                                           target_organisation_id: scalar(:target), fields: ticked_fields,
                                           confirm_duplicate: confirmed?, current_user: current_user)
      return taken_over(result.resource) if result.success?
      return ask(result.errors.to_sentence) if result.code == Actors::TakeOverPerson::DUPLICATE
      return failed(result.errors) if result.code == :validation_failed

      refuse
    end

    private

    # The id of the address in one spelling (dashed, lower case), the one the
    # dialog was drawn with and the actor's lookup compares; nil when it is none.
    def person_id
      @person_id ||= Lalabase::Uuid.dashed(params[:person_id])
    end

    # A contact row of this organisation the viewer may read, or nil. The
    # actor reads it again on submit through People::Lookup.
    def source_row
      policy_scope(Person).find_by(id: person_id, user_id: nil) if person_id
    end

    def targets
      Actors::TakeOverPerson.targets_for(viewer: current_user, source: current_organisation)
    end

    def scalar(key)
      value = params[key]
      value if value.is_a?(String)
    end

    def ticked_fields
      fields = params[:fields]
      fields.is_a?(Array) ? fields.grep(String) : []
    end

    def confirmed?
      target = scalar(:target)
      target.present? && scalar(:confirm_target) == target
    end

    def token
      scalar(:modal_token).to_s[MODAL_TOKEN]
    end

    def taken_over(copy)
      notice = t('controllers.people.takeover.success', source: current_organisation.name)
      redirect_to organisation_people_path(copy.organisation, person_id: copy.id), status: :see_other, notice: notice
    end

    # The dialog again in place of the opening that sent it, with the
    # question; what was chosen stays chosen. The values shown are the source
    # row's, read again with the viewer's right.
    def ask(question)
      return back_to_card(question) unless request.format.turbo_stream?

      @person = source_row
      @targets = targets
      return refuse if @person.nil? || token.nil?

      locals = dialog_locals(token: token).merge(question: question, confirm_target: scalar(:target))
      render turbo_stream: turbo_stream.replace(helpers.person_takeover_modal_instance_id(@person.id, token),
                                                partial: 'organisations/person_takeovers/dialog', locals: locals),
             status: :unprocessable_content
    end

    # The copy was refused by the row's own validations (a value stored under
    # older rules). Only reached after every right was checked, so the reasons
    # tell nothing about the target. The dialog closes, the reasons show.
    def failed(errors)
      message = [t('controllers.people.takeover.failed'), errors.to_sentence].join(' ')
      return back_to_card(message) unless request.format.turbo_stream?

      render turbo_stream: close_dialog_with(message), status: :unprocessable_content
    end

    def back_to_card(message)
      redirect_to organisation_people_path(current_organisation, person_id: person_id), alert: message, status: :see_other
    end

    def close_dialog_with(message)
      streams = [turbo_stream.prepend('flash', partial: 'layouts/flash', locals: { flash: { alert: message } })]
      opening = helpers.person_takeover_modal_instance_id(person_id || params[:person_id].to_s, token)
      streams.unshift(turbo_stream.remove(opening)) if token
      streams
    end

    # The one refusal. In the dialog's frame: the reason in place of the
    # dialog. From the form: that opening closes and the reason shows as a
    # flash. Anything else: back to the list with the reason.
    def refuse
      skip_authorization
      message = t('controllers.people.not_found')
      if request.post? && request.format.turbo_stream?
        render turbo_stream: close_dialog_with(message), status: :not_found
      elsif turbo_frame_request?
        render html: helpers.turbo_frame_tag(request.headers['Turbo-Frame']) {
          helpers.tag.p(message, class: 'py-10 text-center text-sm text-muted')
        }, layout: false, status: :not_found
      else
        redirect_to organisation_people_path(current_organisation), alert: message, status: :see_other
      end
    end

    def render_dialog(token:)
      render html: helpers.turbo_frame_tag(helpers.person_takeover_modal_id(@person.id)) {
        helpers.render(partial: 'organisations/person_takeovers/dialog', locals: dialog_locals(token: token))
      }, layout: false
    end

    def dialog_locals(token:)
      { person: @person, targets: @targets, token: token, target_id: scalar(:target),
        fields: params.key?(:target) ? ticked_fields : Actors::TakeOverPerson::DEFAULT_FIELDS,
        question: nil, confirm_target: nil }
    end
  end
end
