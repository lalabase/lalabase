# frozen_string_literal: true

class Organisations::PostsController < Organisations::BaseController
  include ProjectController
  include TicketListColumns

  before_action :set_ticket
  before_action :set_post, only: %i[show edit update destroy]

  def show
    authorize @post, :show?

    respond_to do |format|
      format.html do
        # If it is a Turbo Frame request, we render the post partial
        if turbo_frame_request?
          render partial: 'organisations/tickets/post', locals: { post: @post, ticket: @ticket }
        else
          redirect_to organisation_project_ticket_path(@current_organisation, @project, @ticket)
        end
      end
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "post_#{@post.id}",
          partial: 'organisations/tickets/post',
          locals: { post: @post, ticket: @ticket }
        )
      end
    end
  end

  def create
    authorize Post.new(ticket: @ticket), :create?

    service = PostUpdateService.new(@ticket, post_params, nil, current_user, params)
    result = service.call
    @post = result.resource

    if result.success?
      handle_ticket_status_change

      if params[:ask_ai] == '1'
        # The whole ask-AI orchestration (prompt build → gated LLM call → usage
        # metering → AI-post write) now lives in Actors::CreateAiPost. It runs AFTER
        # the user's own post is committed, so any failure leaves that post untouched
        # ("continue without an AI post"). We map the failure code back to the SAME
        # flash copy the inline rescue chain used (no new locale keys).
        ai_result = Actors::CreateAiPost.call(
          ticket: @post.ticket, current_user: current_user, organisation: current_organisation
        )
        flash[:alert] = ai_post_error_flash(ai_result) unless ai_result.success?
      end

      # Check for Turbo requests and respond to them accordingly
      respond_to do |format|
        format.turbo_stream do
          # The ticket may have changed
          @ticket.reload

          # Load timeline items and post for display - use TicketTimelineService for correct user preferences
          @timeline_items = TicketTimelineService.new(@ticket, current_user).timeline_items

          streams = []

          # Replace the posts container (replace instead of update for correct rendering)
          streams << turbo_stream.replace(
            "posts-container-#{@ticket.id}",
            partial: 'organisations/tickets/posts_container',
            locals: {
              ticket: @ticket,
              timeline_items: @timeline_items,
              project: @project,
              current_organisation: @current_organisation
            }
          )

          # Update the ticket header (right) so updated_at is immediately visible
          # Desktop detail area
          streams << turbo_stream.replace_all(
            '#ticket_display_frame #ticket-header',
            partial: 'organisations/tickets/ticket_header_show',
            locals: {
              ticket: @ticket,
              current_organisation: @current_organisation,
              project: @project
            }
          )

          # (removed) A direct replace by ID led to collisions with multiple IDs in the DOM

          # Update the ticket row in the list
          streams.concat(ticket_list_row_streams(@ticket, columns: ticket_list_columns(@project)))

          # Close the comment composer: a FRESH render of the composer block (collapse
          # re-connects -> form hidden, button back, editor empty). Nothing else ever
          # closed it - saving used to leave the filled form standing (bug 24.08.2026).
          streams << turbo_stream.replace(
            "new-post-composer-#{@ticket.id}",
            partial: 'organisations/tickets/new_post_composer',
            locals: {
              ticket: @ticket,
              # Explicitly a NEW post: with nil the form partial falls back to @post,
              # which here is the just-saved comment - the "fresh" composer would come
              # back pre-filled and, worse, as an UPDATE form for that comment.
              post: Post.new(ticket: @ticket, user: current_user),
              position: current_user&.preference_store&.prefers_reverse_timeline? ? :top : :bottom
            }
          )

          # Show success message
          streams << turbo_stream.prepend('flash',
                                          partial: 'layouts/flash',
                                          locals: { flash: { notice: t('flash.posts.created') } })

          render turbo_stream: streams
        end

        format.html do
          redirect_to organisation_project_ticket_path(@current_organisation, @ticket.project, @ticket),
                      notice: t('flash.posts.created')
        end
      end
    else
      @post ||= @ticket.posts.build(post_params)

      if result.errors.present?
        result.errors.each do |error|
          @post.errors.add(:base, error)
        end
      end

      redirect_to organisation_project_ticket_path(@current_organisation, @project, @ticket), alert: t('flash.posts.create_error')
    end
  end

  def edit
    authorize @post, :update?

    @post.post_documents.build if @post.post_documents.empty?

    respond_to do |format|
      format.turbo_stream do
        # If a Turbo Frame made the request, return frame HTML instead of streams
        if turbo_frame_request?
          render partial: 'organisations/posts/edit', layout: false
        else
          render turbo_stream: turbo_stream.replace(
            "post_#{@post.id}",
            partial: 'organisations/posts/edit'
          )
        end
      end
      format.html do
        if turbo_frame_request?
          render partial: 'organisations/posts/edit', layout: false
        else
          render :edit
        end
      end
    end
  end

  def cancel
    @post = @ticket.posts.find(params[:id])

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "post_#{@post.id}",
          NeoPostComponent.new(
            post: @post,
            current_user: current_user,
            current_organisation: @current_organisation,
            turbo_frame: true
          )
        )
      end
      format.html { redirect_to organisation_project_ticket_path(@current_organisation, @project, @ticket) }
    end
  end

  def update
    authorize @post, :update?

    service = PostUpdateService.new(@ticket, post_params, params[:id], current_user, params)
    result = service.call
    @post = result.resource

    if result.success?
      @post.reload
      # The ticket may have changed (e.g. a new post was added that could mean a status change)
      @ticket.reload

      respond_to do |format|
        format.turbo_stream do
          streams = []

          # Update post
          streams << turbo_stream.replace(
            "post_#{@post.id}",
            NeoPostComponent.new(
              post: @post,
              current_user: current_user,
              current_organisation: @current_organisation,
              turbo_frame: true
            )
          )

          # Update the ticket header (right) so updated_at is immediately visible
          streams << turbo_stream.replace_all(
            '#ticket_display_frame #ticket-header',
            partial: 'organisations/tickets/ticket_header_show',
            locals: {
              ticket: @ticket,
              current_organisation: @current_organisation,
              project: @project
            }
          )

          # Update the ticket row in the ticket list
          streams.concat(ticket_list_row_streams(@ticket, columns: ticket_list_columns(@project)))

          render turbo_stream: streams
        end

        format.html { redirect_to organisation_project_ticket_path(@current_organisation, @ticket.project, @ticket) }
      end
    else
      @post ||= @ticket.posts.find(params[:id])

      if result.errors.present?
        result.errors.each do |error|
          @post.errors.add(:base, error)
        end
      end

      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @post, :destroy?

    # Save the ID of the post before deletion for the turbo_stream response
    post_id = @post.id

    actor = Actors::DestroyPost.new(id: @post.id)
    actor.call

    # The ticket may have changed after the post was deleted
    @ticket&.reload

    respond_to do |format|
      format.html { redirect_to organisation_project_ticket_path(@current_organisation, @project, @ticket), notice: t('flash.posts.deleted') }
      format.turbo_stream do
        streams = []

        # Remove post from the DOM
        streams << turbo_stream.remove("post_#{post_id}")

        # Update the ticket row in the list
        if @ticket
          # Update the ticket header (right) so updated_at is immediately visible
          streams << turbo_stream.replace_all(
            '#ticket_display_frame #ticket-header',
            partial: 'organisations/tickets/ticket_header_show',
            locals: {
              ticket: @ticket,
              current_organisation: @current_organisation,
              project: @project
            }
          )

          streams.concat(ticket_list_row_streams(@ticket, columns: ticket_list_columns(@project)))
        end

        # Show success message
        streams << turbo_stream.prepend('flash',
                                        partial: 'layouts/flash',
                                        locals: { flash: { notice: t('flash.posts.deleted') } })

        render turbo_stream: streams
      end
    end
  end

  private

  def set_ticket
    @ticket = @project.tickets.find(params[:ticket_id])
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = t('flash.posts.ticket_not_found')
    redirect_to organisation_project_tickets_path(@current_organisation, @project) and return
  end

  def set_post
    @post = @ticket.posts.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = t('flash.posts.not_found')
    redirect_to organisation_project_ticket_path(@current_organisation, @project, @ticket) and return
  end

  def post_params
    params_to_process = params.require(:post).permit(
      :content,
      :is_private,
      post_documents_attributes: %i[id post_document_file _destroy],
      post_document_files: []
    )

    params_to_process.delete(:post_document_files)

    params_to_process
  end

  # Best-effort status quick-change while commenting. Shares Actors::ApplyTicketChanges
  # (a set of one, doc/ticket_bulk_edit_plan.md D13) with the Kanban path and the bulk
  # panel: one source for the value validation AND the skip-validation safety (F2), so
  # a legacy-invalid neighbour attribute never blocks the status write here either. A disallowed status or missing definition comes back
  # as a failure Result we INTENTIONALLY ignore: this side effect must never break the
  # comment flow (mirrors the old silent `return`). The Pundit check stays in the
  # controller.
  def handle_ticket_status_change
    return unless params[:ticket_status].present?
    return unless @ticket.present?
    return unless policy(@ticket).update?

    Actors::ApplyTicketChanges.call(
      project: @project, ticket_ids: [@ticket.id], current_user: current_user,
      changes: [{ 'field' => 'status', 'value' => params[:ticket_status] }]
    )
  end

  # Maps a CreateAiPost failure code to the EXISTING ask-AI flash copy (no new locale
  # keys). Any unmapped/unexpected code (e.g. :internal_error from a missing AI user,
  # or a validation failure on the AI post) falls back to the generic ai_fallback —
  # matching the old broad `rescue StandardError` branch.
  def ai_post_error_flash(result)
    case result.code
    when :ai_disabled then t('shared.ai.disabled_member_hint')
    when :quota_exceeded then t('shared.ai.quota_exhausted_member_hint')
    when :not_configured then t('flash.posts.ai_not_configured')
    when :invalid_key then t('flash.posts.ai_invalid_key')
    when :provider_error then t('flash.posts.ai_error', error: result.errors.first)
    else t('flash.posts.ai_fallback')
    end
  end
end
