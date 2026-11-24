# frozen_string_literal: true

# The management section "Tags" (NavigationHelper::SETTINGS_TABS, Belegungstabelle
# F44): the organisation's tags with the number of entries each hangs on, and the
# three ways of looking after them.
#
#   index      the list: name, uses per kind and in all; search, sort, pages
#   edit       the form to rename          -> update -> Actors::RenameTag
#   new_merge  the form to merge           -> merge  -> Actors::MergeTags
#   destroy    from the row's menu, after a question that names the uses
#
# A tag comes into being by tagging (Taggable#tag_list=), so nothing here creates
# one. Account admins only (TagPolicy). Renaming and merging rewrite the tag rules
# of the saved filters as well: a rule names a tag by its name.
class Organisations::TagsController < Organisations::BaseController
  include Pageable

  # The orders of the list, each with the direction a first click on its head
  # gives; a click on the head of the active order turns it round.
  SORTS = { 'name' => 'asc', 'uses' => 'desc' }.freeze
  DIRECTIONS = %w[asc desc].freeze
  # The longest search the list reads; a longer one is cut, never refused.
  MAX_QUERY_LENGTH = 100

  before_action :set_tag, except: :index
  helper_method :list_sort, :list_direction, :list_query

  def index
    authorize Tag
    all_tags = policy_scope(Tag)
    @tag_count = all_tags.count
    tags = list_query.present? ? all_tags.where('tags.name ILIKE ?', "%#{Tag.sanitize_sql_like(list_query)}%") : all_tags
    @pagy, @tags = paginate(tags.with_usage_counts.reorder(*list_order), count: tags.count)
  end

  def edit
    authorize @tag
    @name = @tag.name
    @usage = usage_of(@tag)
  end

  def update
    authorize @tag
    @name = name_param
    old_name = @tag.name
    result = Actors::RenameTag.call(tag: @tag, name: @name, current_user: current_user)
    if result.success?
      # The name it had (another spelling of it included) changes nothing and says nothing.
      notice = t('flash.tags.renamed', old: old_name, new: @tag.name) unless @tag.name == old_name
      return redirect_to organisation_tags_path(current_organisation), notice: notice
    end

    @error = result.errors.to_sentence
    # The tag that has the name already: the form offers to merge into it instead.
    @taken = policy_scope(Tag).where.not(id: @tag.id).find_by(name: Tag.normalize_name(@name)) if result.code == :name_taken
    @usage = usage_of(@tag)
    render :edit, status: :unprocessable_content
  end

  def new_merge
    authorize @tag, :merge?
    @usage = usage_of(@tag)
    @targets = merge_targets
    @target_id = id_param(:target_id)
  end

  def merge
    authorize @tag
    target = merge_targets.find_by(id: id_param(:target_id))
    return refuse_merge(t('services.actors.merge_tags.no_target')) unless target

    result = Actors::MergeTags.call(source: @tag, target: target, current_user: current_user)
    return refuse_merge(result.errors.to_sentence) unless result.success?

    redirect_to organisation_tags_path(current_organisation),
                notice: t('flash.tags.merged', source: @tag.name, target: target.name)
  end

  def destroy
    authorize @tag
    @tag.destroy!
    redirect_to organisation_tags_path(current_organisation), notice: t('flash.tags.deleted', name: @tag.name),
                                                              status: :see_other
  end

  private

  # The search of the list: a string from the address, stripped and cut, or ''.
  def list_query
    @list_query ||= params[:q].is_a?(String) ? params[:q].strip.first(MAX_QUERY_LENGTH) : ''
  end

  def list_sort
    SORTS.key?(params[:sort]) ? params[:sort] : 'name'
  end

  def list_direction
    DIRECTIONS.include?(params[:direction]) ? params[:direction] : SORTS.fetch(list_sort)
  end

  # Through the policy scope: a tag of another organisation is not found (404),
  # whatever its id.
  def set_tag
    @tag = policy_scope(Tag).find(params[:id])
  end

  # The tag again, with its counts: the forms name how many entries a change reaches.
  def usage_of(tag)
    Tag.with_usage_counts.find(tag.id)
  end

  # Every other tag of the organisation, by name: what the tag can go into.
  def merge_targets
    policy_scope(Tag).where.not(id: @tag.id).order(:name)
  end

  # The order the list was asked for (SORTS); tags with as many uses keep the
  # order of their names.
  def list_order
    name = Tag.arel_table[:name]
    uses = Arel.sql('tag_usage.uses_count')
    case [list_sort, list_direction]
    when %w[uses desc] then [uses.desc, name.asc]
    when %w[uses asc] then [uses.asc, name.asc]
    when %w[name desc] then [name.desc]
    else [name.asc]
    end
  end

  def refuse_merge(message)
    @error = message
    @usage = usage_of(@tag)
    @targets = merge_targets
    @target_id = id_param(:target_id)
    render :new_merge, status: :unprocessable_content
  end

  # The typed name, '' when the form sent none or something that is no string.
  def name_param
    tag = params[:tag]
    name = tag[:name] if tag.is_a?(ActionController::Parameters)
    name.is_a?(String) ? name : ''
  end

  # An id from the request, nil when it is no string: a list or a hash names no tag.
  def id_param(key)
    params[key].presence if params[key].is_a?(String)
  end
end
