# frozen_string_literal: true

class Organisations::NotesController < Organisations::BaseController
  include ObjectListController
  include ActionView::RecordIdentifier

  # Setup for sorting, paging and search
  setup_sortable Note
  setup_pagination 5
  setup_searchable Note, %i[title description plain_text_version]

  # ========================================================================
  # TECHNICAL DOCUMENTATION: PAGINATION WITH TURBO FRAMES
  # ========================================================================
  #
  # The notes pagination uses Turbo Frames for partial page updates without a
  # full page reload. This implementation serves as a reference for
  # other list views (tickets, documents, etc.).
  #
  # ## ARCHITECTURE OVERVIEW
  #
  # 1. **Turbo Frame structure**
  #    - A single frame `notes_results` wraps the entire table
  #    - Pagination updates only this frame, not the whole page
  #    - The detail view is preserved in a separate frame
  #
  # 2. **Controller flow**
  #    - The `index` action always renders the complete template
  #    - On Turbo Frame requests, only the frame content is extracted automatically
  #    - No special render instructions for frames needed
  #
  # 3. **View hierarchy**
  #    ```
  #    index.html.erb
  #    ├── _notes_results.html.erb (Turbo Frame wrapper)
  #    │   ├── Table with notes
  #    │   ├── _note_row.html.erb (for each row)
  #    │   └── _pagination_nav_compact.html.erb
  #    └── note_display_frame (detail view, separate frame)
  #    ```
  #
  # ## IMPLEMENTATION DETAILS
  #
  # ### 1. Turbo Frame setup (_notes_results.html.erb)
  # ```erb
  # <turbo-frame id="notes_results" data-controller="pagination">
  #   <!-- Entire table content -->
  #   <!-- Pagination Navigation -->
  # </turbo-frame>
  # ```
  #
  # ### 2. Controller logic (ObjectListController)
  # - Uses standard Rails `render :index` for all requests
  # - Turbo detects frame requests automatically via header
  # - No `format.turbo_stream` blocks needed for pagination
  #
  # ### 3. Pagination navigation (_pagination_nav_compact.html.erb)
  # - Links have the `data-turbo-frame="notes_results"` attribute
  # - URLs point to the index action with a page parameter
  # - The frame target ensures a partial update
  #
  # ### 4. URL parameter handling
  # - All relevant parameters are preserved during pagination:
  #   - `page`: Current page
  #   - `items`: Entries per page
  #   - `search`: Search term
  #   - `note_id`: Selected note (for the detail view)
  #   - `smart_folder_id`: Active smart folder
  #   - `sort`: Sorting
  #
  # ### 5. Detail view persistence
  # - The detail frame (`note_display_frame`) is outside the `notes_results` frame
  # - On pagination only `notes_results` is updated
  # - The detail view remains visible unchanged
  #
  # ## ADVANTAGES OF THIS IMPLEMENTATION
  #
  # 1. **Simplicity**: No complex JavaScript logic needed
  # 2. **Performance**: Only relevant DOM parts are updated
  # 3. **State preservation**: The detail view and other UI elements are preserved
  # 4. **SEO-friendly**: Works even without JavaScript (graceful degradation)
  # 5. **Browser history**: URLs are bookmarkable
  #
  # ## COMMON PROBLEMS AND SOLUTIONS
  #
  # ### Problem: "undefined" in URLs
  # **Cause**: JavaScript tries to build undefined values into URLs
  # **Solution**: URL validation in pagination_nav_compact.html.erb
  #
  # ### Problem: Detail view disappears
  # **Cause**: Frame nesting or wrong frame target
  # **Solution**: Place the detail frame outside the pagination frame
  #
  # ### Problem: UUID interpreted as format
  # **Cause**: Rails interprets ".uuid-string" as a format extension
  # **Solution**: Explicit format: :html in URL helpers
  #
  # ### Problem: Layout jumps on pagination
  # **Cause**: CSS classes are lost on frame update
  # **Solution**: Store the layout state in sessionStorage
  #
  # ## BEST PRACTICES
  #
  # 1. **Keep frame IDs consistent**: `{resource}_results` pattern
  # 2. **Pass all parameters through**: Lose nothing on navigation
  # 3. **Simple frame structure**: No deep nesting
  # 4. **Standard Rails patterns**: No custom rendering for frames
  # 5. **Progressive enhancement**: Works even without JavaScript
  #
  # ========================================================================

  before_action :redirect_to_knowledge, only: [:index]
  before_action :authorize_note_write, only: %i[new create edit update destroy]

  rescue_from ActiveRecord::RecordNotFound, with: :handle_not_found

  # Define the object type for the ObjectListController concern
  def object_type
    'Note'
  end

  # Always use index.html.erb (as with tickets) –
  # the template handles both cases (with/without selected_note)
  def with_object_template
    :index
  end

  def list_only_template
    :index
  end

  # Override to avoid over-stubbing of policy_scope in tests
  # and to ensure consistent fetching of project notes
  def project_objects
    @project.notes
  end

  # Override the detail frame ID if needed — default is the frame of the
  # Knowledge view (the only remaining detail display for notes).
  def detail_frame_id
    params[:frame_id].presence || 'knowledge_display_frame'
  end

  # Override of ObjectListController to use session-based selection
  def set_selected_object
    note_id = params[:note_id]

    if note_id.present?
      begin
        @selected_object = project_objects.find(note_id)
        @selected_note = @selected_object
      rescue ActiveRecord::RecordNotFound
        @selected_object = nil
        @selected_note = nil
      end
    else
      @selected_object = nil
      @selected_note = nil
    end
  end

  # Override of build_results_locals
  def build_results_locals
    locals = super
    locals[:selected_note] = @selected_note if @selected_note.present?
    locals
  end

  # Custom Actions

  def show
    set_object
    authorize @note

    # Special parameter frame=content for Turbo Frame requests
    if params[:frame] == 'content'
      # Render the content with the required Turbo Frame wrapper
      # Support custom frame_id for Knowledge view integration
      frame_id = params[:frame_id].presence || 'knowledge_display_frame'
      render html: helpers.turbo_frame_tag(frame_id) {
        helpers.render(partial: 'organisations/notes/note_show', locals: { note: @note, detail_frame_id: frame_id })
      }.html_safe, layout: false
      return
    end

    # Standalone calls land in the Knowledge view with the selected note
    # (analogous to documents#show) — a dedicated notes list view no longer exists.
    redirect_to organisation_project_knowledge_index_path(
      @current_organisation, @project, note_id: @note.id, type: 'all'
    )
  end

  def new
    # There is one note form, and it lives on the knowledge page. Only that page's Turbo
    # Frame gets the form alone (frame=content). Every other request (the dashboard's
    # "+", the phone's "+", a bookmark) lands on the knowledge page with the form as a
    # state of its address (?new=note, KnowledgeController#set_new_type).
    unless params[:frame] == 'content' && turbo_frame_request?
      redirect_to organisation_project_knowledge_index_path(@current_organisation, @project, new: 'note')
      return
    end

    @note = Note.new
    frame_id = params[:frame_id].presence || 'knowledge_display_frame'
    render html: helpers.turbo_frame_tag(frame_id) {
      helpers.render(partial: 'organisations/notes/note_new_for_frame',
                     locals: { note: @note, detail_frame_id: frame_id })
    }.html_safe, layout: false
    nil
  end

  def create
    actor = Actors::SaveNote.new(project: @project, params: note_params, current_user: current_user)
    result = actor.call
    @note = actor.record

    if result.success?
      # The inline form targets `_top`, so this redirect becomes a full page visit that
      # shows the list with the new note and its detail. knowledge#index must answer
      # HTML for that to work (see the note there).
      redirect_to organisation_project_knowledge_index_path(
        @current_organisation, @project, note_id: @note.id, type: 'all'
      ), notice: t('flash.notes.created')
    else
      alert = t('flash.notes.save_error', errors: result.errors.join(', '))
      respond_to do |format|
        format.turbo_stream do
          # Form back into the detail frame, error as flash. There is no `new` template
          # to render: the form exists only as this partial.
          render turbo_stream: [
            turbo_stream.update(detail_frame_id,
                                partial: 'organisations/notes/note_new_for_frame',
                                locals: { note: @note, detail_frame_id: detail_frame_id }),
            turbo_stream.prepend('flash', partial: 'layouts/flash', locals: { flash: { alert: alert } })
          ], status: :unprocessable_entity
        end
        format.html do
          redirect_to organisation_project_knowledge_index_path(@current_organisation, @project, type: 'all'),
                      alert: alert
        end
      end
    end
  end

  def edit
    set_object
    authorize @note

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.update(detail_frame_id, partial: 'organisations/notes/note_edit', locals: { note: @note, detail_frame_id: detail_frame_id })
        ]
      end
      format.html do
        redirect_to organisation_project_knowledge_index_path(
          @current_organisation, @project, note_id: @note.id, type: 'all'
        )
      end
    end
  end

  def update
    actor = Actors::SaveNote.new(project: @project, params: note_params, id: params[:id], current_user: current_user)
    result = actor.call
    @note = actor.record

    if result.success?
      respond_to do |format|
        format.turbo_stream do
          streams = []

          # Update content
          streams << turbo_stream.update(detail_frame_id,
                                         partial: 'organisations/notes/note_show',
                                         locals: { note: @note, detail_frame_id: detail_frame_id })

          # Update the row in the Knowledge list (the only remaining list)
          streams << turbo_stream.replace_all("tr[data-item-id='#{@note.id}']",
                                              partial: 'organisations/knowledge/knowledge_row',
                                              locals: { item: @note, selected_item: @note })

          # Show flash message
          streams << turbo_stream.prepend('flash',
                                          partial: 'layouts/flash',
                                          locals: { flash: { notice: t('flash.notes.updated') } })

          render turbo_stream: streams
        end
        format.html { redirect_to organisation_project_note_path(@current_organisation, @project, @note), notice: t('flash.notes.updated') }
      end
    else
      respond_to do |format|
        format.turbo_stream do
          # Form with validation errors back into the detail frame
          render turbo_stream: turbo_stream.update(
            detail_frame_id,
            partial: 'organisations/notes/note_edit',
            locals: { note: @note, detail_frame_id: detail_frame_id }
          ), status: :unprocessable_entity
        end
        format.html { render :edit, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    set_object
    begin
      deletion_success = @note.destroy

      respond_to do |format|
        if deletion_success
          format.turbo_stream do
            # Remove the row from the Knowledge list, clear the detail, show flash
            render turbo_stream: [
              turbo_stream.remove_all("tr[data-item-id='#{@note.id}']"),
              turbo_stream.update(
                detail_frame_id,
                partial: 'shared/empty_content',
                locals: {
                  message: t('views.organisations.knowledge.index.item_deleted_note'),
                  description: t('views.organisations.knowledge.index.item_deleted_description'),
                  icon_class: 'bi bi-journal-text'
                }
              ),
              turbo_stream.prepend('flash',
                                   partial: 'layouts/flash',
                                   locals: { flash: { notice: t('flash.notes.deleted') } })
            ]
          end

          format.html do
            redirect_to organisation_project_knowledge_index_path(@current_organisation, @project, type: 'note'),
                        notice: t('flash.notes.deleted')
          end
        else
          format.turbo_stream do
            render turbo_stream: turbo_stream.prepend(
              'flash',
              partial: 'layouts/flash',
              locals: { flash: { alert: t('flash.notes.delete_error') } }
            )
          end

          format.html do
            redirect_to organisation_project_note_path(@current_organisation, @project, @note),
                        alert: t('flash.notes.delete_error')
          end
        end
      end
    rescue StandardError => e
      Rails.logger.error "Error deleting the note: #{e.message}"

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.prepend(
            'flash',
            partial: 'layouts/flash',
            locals: { flash: { alert: t('flash.notes.delete_error_detail', error: e.message) } }
          )
        end

        format.html do
          redirect_to organisation_project_note_path(@current_organisation, @project, @note),
                      alert: t('flash.notes.delete_error_detail', error: e.message)
        end
      end
    end
  end

  private

  # Redirect index requests to the unified Knowledge view: the dedicated
  # notes list view no longer exists (not even as a frame).
  # A preselected note travels along, into the FULL knowledge list (type=all,
  # the same handover #show makes). PowerSearchService#result_link links every
  # note hit as notes_path(note_id:); a handover that kept only the type opened
  # the list with nothing selected, and the controller spec pinned that loss.
  def redirect_to_knowledge
    target = params[:note_id].present? ? { note_id: params[:note_id], type: 'all' } : { type: 'note' }
    redirect_to organisation_project_knowledge_index_path(@current_organisation, @project, **target)
  end

  # Checks whether the user has write permissions for the notes area
  def authorize_note_write
    case action_name
    when 'new', 'create'
      dummy_note = Note.new(project: @project)
      begin
        authorize(dummy_note, :create?)
      rescue Pundit::NotAuthorizedError
        flash[:alert] = t('flash.notes.no_create_permission')
        redirect_to organisation_project_notes_path(@current_organisation, @project) and return
      end
    when 'edit', 'update'
      begin
        authorize(@note, :update?)
      rescue Pundit::NotAuthorizedError
        flash[:alert] = t('flash.notes.no_edit_permission')
        redirect_to organisation_project_note_path(@current_organisation, @project, @note) and return
      end
    when 'destroy'
      begin
        authorize(@note, :destroy?)
      rescue Pundit::NotAuthorizedError
        flash[:alert] = t('flash.notes.no_delete_permission')
        redirect_to organisation_project_note_path(@current_organisation, @project, @note) and return
      end
    end
  end

  def note_params
    # lock_version: optimistic locking — the form submits the version the user loaded; a
    # concurrent edit then fails with StaleObjectError instead of silently overwriting.
    # No create_embeddings: the column is the server's (true by default, the seam
    # decides), never a form field any more (doc/notizen_immer_indexiert_plan.md).
    params.require(:note).permit(:title, :content, :description, :tag_list, :lock_version)
  end

  # Authorize area access for read access is provided by the ObjectListController
  def action_permission_level
    case action_name
    when 'index', 'show'
      :read
    else
      :write
    end
  end
end
