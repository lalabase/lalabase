# frozen_string_literal: true

class Organisations::TagsController < Organisations::BaseController
  include Sortable
  include Pageable
  include Searchable

  setup_sortable Tag, 'name'

  before_action :authenticate_user!
  before_action :set_tag, only: %i[show edit update destroy]
  after_action :verify_authorized, except: :index
  after_action :verify_policy_scoped, only: :index

  def index
    @tags = policy_scope(Tag)

    # Apply search if params are present
    @tags = @tags.where('name ILIKE ?', "%#{search_param}%") if search_param.present?

    # Apply sorting
    @tags = apply_sorting(@tags)

    respond_to do |format|
      format.html do
        # Apply pagination for HTML view
        @pagy, @tags = pagy(@tags)
      end
      format.json do
        # Return all tags for autocomplete
        render json: @tags.map { |tag| { id: tag.id, name: tag.name } }
      end
    end
  end

  def show
    authorize @tag
    @taggables = all_taggable_items.to_a.sort_by(&:updated_at).reverse
  end

  def new
    @tag = Tag.new
    authorize @tag
  end

  def create
    @tag = Tag.new(tag_params)
    @tag.user = current_user
    authorize @tag

    if @tag.save
      redirect_to organisation_tags_path, notice: t('flash.tags.created')
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @tag
  end

  def update
    authorize @tag
    if @tag.update(tag_params)
      redirect_to organisation_tags_path, notice: t('flash.tags.updated')
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @tag
    @tag.destroy
    redirect_to organisation_tags_path, notice: t('flash.tags.deleted')
  end

  private

  def set_tag
    # policy_scope → unknown/foreign tag ids raise RecordNotFound → 404 (no existence leak).
    @tag = policy_scope(Tag).find(params[:id])
  end

  def tag_params
    params.require(:tag).permit(:name)
  end

  def all_taggable_items
    # Only tagged items from projects the user can access — otherwise the tag detail page
    # leaks titles/projects of foreign-project notes/documents/tickets. includes(:project)
    # preloads the project rendered per row (avoids N+1).
    document_project_ids = selectable_projects(area: :documents).select(:id)
    ticket_project_ids = selectable_projects(area: :tickets).select(:id)

    notes = @tag.notes.where(project_id: document_project_ids).includes(:project)
    documents = @tag.documents.where(project_id: document_project_ids).includes(:project)
    tickets = @tag.tickets.where(project_id: ticket_project_ids).includes(:project)

    notes + documents + tickets
  end

  # Searchable concern methods
  def search_param
    params[:search]
  end
end
