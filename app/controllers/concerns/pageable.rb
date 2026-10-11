# frozen_string_literal: true

# app/controllers/concerns/pageable.rb
module Pageable
  extend ActiveSupport::Concern
  include Pagy::Backend

  DEFAULT_PER_PAGE = 20
  MIN_PER_PAGE = 1
  MAX_PER_PAGE = 200

  PAGINATION_PARAMS = %i[
    page items limit smart_folder_id project_id
    ticket_id time_session_group_id start_date end_date
    billing_status project_id_filter
  ].freeze

  EXTENDED_PARAMS = (%i[search context_type filter] + PAGINATION_PARAMS).freeze

  included do
    helper_method :items_per_page, :pagination_params, :sort_and_pagination_params
    class_attribute :default_per_page if respond_to?(:class_attribute)
  end

  module ClassMethods
    def setup_pagination(per_page = DEFAULT_PER_PAGE)
      self.default_per_page = per_page
    end
  end

  # Applies pagination to a query.
  # Returns an array [pagy_instance, records].
  def paginate(query, options = {})
    permitted = permitted_pagination_params

    page = [permitted[:page].to_i, 1].max
    per_page = options[:items] || items_per_page

    pagy_opts = {
      page: page,
      limit: per_page,
      params: build_pagy_url_params(permitted, per_page)
    }
    # A caller that knows the total hands it in. Pagy would otherwise call
    # .count(:all) itself, and on a GROUPED relation that returns a Hash of every
    # group -- the whole result set in memory, to learn its size.
    pagy_opts[:count] = options[:count] if options.key?(:count)
    pagy_opts[:overflow] = options[:overflow] if options.key?(:overflow)

    pagy(query, **pagy_opts)
  end

  # Determines the number of items per page.
  # Priority: 1. URL parameter → 2. user DB preference → 3. controller default → 4. DEFAULT_PER_PAGE
  def items_per_page
    permitted = params.permit(:items, :limit)

    # 1. URL parameter takes precedence
    if permitted[:items].present?
      return sanitize_per_page(permitted[:items])
    elsif permitted[:limit].present?
      return sanitize_per_page(permitted[:limit])
    end

    # 2. User preference from DB
    if respond_to?(:current_user) && current_user.respond_to?(:items_per_page_preference)
      value = current_user.items_per_page_preference
      return value if value.is_a?(Integer) && value > 0
    end

    # 3. Controller default or absolute default
    self.class.respond_to?(:default_per_page) && self.class.default_per_page.present? ? self.class.default_per_page.to_i : DEFAULT_PER_PAGE
  end

  # Parameters for pagination links
  def pagination_params
    permitted = permitted_pagination_params

    page = permitted[:page].present? ? [permitted[:page].to_i, 1].max : nil

    items_value = if permitted[:items].present?
                    permitted[:items]
                  elsif permitted[:limit].present?
                    permitted[:limit]
                  else
                    items_per_page
                  end

    result = { page: page, items: items_value }
    result[:smart_folder_id] = permitted[:smart_folder_id] if permitted[:smart_folder_id].present?
    result
  end

  # Combines sorting and pagination parameters for links
  def sort_and_pagination_params
    sort_parameters = respond_to?(:sort_params) ? (sort_params || {}) : {}
    pagination_parameters = pagination_params

    # Ensure SmartFolder ID via permitted params
    permitted = permitted_pagination_params
    if permitted[:smart_folder_id].present?
      sort_parameters[:smart_folder_id] = permitted[:smart_folder_id] unless sort_parameters.key?(:smart_folder_id)
      pagination_parameters[:smart_folder_id] = permitted[:smart_folder_id] unless pagination_parameters.key?(:smart_folder_id)
    end

    # Remove the page parameter when clicking a sort column, to return to page 1
    if params[:sort].present? && params[:sort][:column].present?
      pagination_parameters.except(:page).merge(sort_parameters)
    else
      pagination_parameters.merge(sort_parameters)
    end
  end

  # Renders Turbo-Stream responses for sorting and pagination
  def respond_to_sort_and_paginate(pagy_instance, collection, frame_id, partial_path, locals = {})
    permitted = params.permit(*EXTENDED_PARAMS, sort: %i[column direction])

    active_smart_folder = load_smart_folder(permitted[:smart_folder_id])

    combined_locals = build_combined_locals(pagy_instance, collection, permitted, active_smart_folder, locals)

    @pagy = pagy_instance unless defined?(@pagy) && @pagy.present?

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(frame_id, partial: partial_path, locals: combined_locals)
        ]
      end
      format.html { render :index }
    end
  end

  # NOTE: there used to be a second pagy_url_for here, a controller-side twin of
  # the one in ApplicationHelper. It was unreachable: pagy_url_for is called from
  # pagy_nav in the VIEW, and this concern never exposed it via helper_method.
  # Proven rather than assumed -- putting `raise` in its body left 2664 request
  # and view examples green. Two implementations of one URL rule, the better one
  # of them dead, is also why the billing list (W5) hand-rolled its own links.
  # One builder now, in ApplicationHelper.

  private

  def permitted_pagination_params
    params.permit(*PAGINATION_PARAMS)
  end

  def sanitize_per_page(value)
    value.to_i.clamp(MIN_PER_PAGE, MAX_PER_PAGE)
  end

  def build_pagy_url_params(permitted, per_page)
    url_params = { items: per_page }
    url_params[:smart_folder_id] = permitted[:smart_folder_id] if permitted[:smart_folder_id].present?
    url_params[:project_id] = permitted[:project_id] if permitted[:project_id].present?
    url_params
  end

  def load_smart_folder(smart_folder_id)
    return nil if smart_folder_id.blank?

    if respond_to?(:policy_scope)
      policy_scope(SmartFolder).find(smart_folder_id)
    else
      SmartFolder.find(smart_folder_id)
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "respond_to_sort_and_paginate: Failed to load SmartFolder: #{e.message}"
    nil
  end

  def build_combined_locals(pagy_instance, collection, permitted, active_smart_folder, locals)
    combined = {
      pagy: pagy_instance,
      collection: collection,
      sortable_header: true,
      smart_folder_id: permitted[:smart_folder_id],
      active_smart_folder: active_smart_folder || instance_variable_get(:@active_smart_folder),
      project_id: permitted[:project_id]
    }.merge(locals)

    if collection.respond_to?(:model)
      collection_name = collection.model.name.underscore.pluralize.to_sym
      combined[collection_name] ||= collection
    end

    combined
  end
end
