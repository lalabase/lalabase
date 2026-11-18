# frozen_string_literal: true

# app/controllers/concerns/pageable.rb
module Pageable
  extend ActiveSupport::Concern

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
  # Returns an array [Pagination::Page, records].
  #
  # Options:
  #   items:    the page size, where the list has a rule of its own for it
  #   count:    the total, from a caller that knows it (a GROUPED relation would
  #             be loaded whole to learn its size, see Pagination::Page.of)
  #   past_end: :last answers a page behind the end with the last page; the
  #             default is an empty page
  def paginate(query, options = {})
    Pagination::Page.of(
      query,
      page: permitted_pagination_params[:page],
      limit: options[:items] || items_per_page,
      count: options[:count],
      past_end: options.fetch(:past_end, :empty)
    )
  end

  # A page size the reader asked for, as the next requests will read it back:
  # at least 1, at most MAX_PER_PAGE. nil when the value names no size (absent,
  # blank, no number, below 1, a list or a hash: Pagination::Page.size).
  # ApplicationController stores the `?items=` of every request through this, so
  # no request saves a size a list would then load in one piece.
  def self.storable_per_page(value)
    Pagination::Page.size(value)&.clamp(MIN_PER_PAGE, MAX_PER_PAGE)
  end

  # Determines the number of items per page.
  # Priority: 1. URL parameter → 2. user DB preference → 3. controller default → 4. DEFAULT_PER_PAGE
  # Every answer stays within MIN_PER_PAGE and MAX_PER_PAGE, the stored preference
  # too: it was written without a ceiling until 18.11.2026, and a full page load
  # reads it without the `?items=` that ensure_items_parameter would have set.
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
      return [value, MAX_PER_PAGE].min if value.is_a?(Integer) && value > 0
    end

    # 3. Controller default or absolute default
    self.class.respond_to?(:default_per_page) && self.class.default_per_page.present? ? self.class.default_per_page.to_i : DEFAULT_PER_PAGE
  end

  # Parameters for pagination links
  def pagination_params
    permitted = permitted_pagination_params

    # The reading of the page number is Pagination::Page's, as in #paginate.
    page = Pagination::Page.number(permitted[:page]) if permitted[:page].present?

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

  # The address of a page link is built in the view: PaginationHelper#page_url_for
  # and #pagination_page_url. This concern builds none.

  private

  def permitted_pagination_params
    params.permit(*PAGINATION_PARAMS)
  end

  def sanitize_per_page(value)
    value.to_i.clamp(MIN_PER_PAGE, MAX_PER_PAGE)
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
