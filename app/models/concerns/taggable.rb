# frozen_string_literal: true

module Taggable
  extend ActiveSupport::Concern

  included do
    has_many :taggings, as: :taggable, dependent: :delete_all
    has_many :tags, through: :taggings

    after_save :process_tag_list_changes
  end

  def tag_list
    if tags.loaded?
      tags.map(&:name)
    else
      tags.pluck(:name)
    end
  end

  def tag_list=(names)
    @tag_names_to_process = names
    @tag_list_changed = true
    process_tag_list_changes if persisted?
  end

  private

  def process_tag_list_changes
    return unless @tag_list_changed

    names = normalize_tag_names(@tag_names_to_process)
    current_tags = tags.pluck(:name)

    remove_obsolete_tags(current_tags - names)
    add_missing_tags(names - current_tags)

    @tag_names_to_process = nil
    @tag_list_changed = false
  end

  def normalize_tag_names(input)
    names = input.presence || []
    names = names.split(Tag::NAME_SEPARATOR) if names.is_a?(String)
    names.map { |n| Tag.normalize_name(n) }.reject(&:blank?).uniq
  end

  def remove_obsolete_tags(tag_names)
    return if tag_names.empty?

    taggings.joins(:tag).where(tags: { name: tag_names }).destroy_all
  end

  def add_missing_tags(tag_names)
    return if tag_names.empty?

    org_id = organisation_id
    existing_tags = Tag.where(name: tag_names, organisation_id: org_id).index_by(&:name)

    new_tags = tag_names.reject { |name| existing_tags.key?(name) }
    if new_tags.any?
      Tag.insert_all(
        new_tags.map { |name| { name: name, organisation_id: org_id, created_at: Time.current, updated_at: Time.current } },
        unique_by: :index_tags_on_name_and_organisation_id
      )
      existing_tags = Tag.where(name: tag_names, organisation_id: org_id).index_by(&:name)
    end

    tag_names.each do |tag_name|
      taggings.create!(tag: existing_tags.fetch(tag_name))
    end
  end

  class_methods do
    # @param name [String, Array<String>] tag name(s)
    # @param options [Hash]
    # @option options [Boolean] :match_all Only entries with ALL tags (default: false)
    # @return [ActiveRecord::Relation]
    def tagged_with(name, options = {})
      match_all = options[:match_all] || false

      names = Array(name).map { |n| n.to_s.strip }.reject(&:blank?)
      return none if names.empty?

      tag_ids = Tag.where(name: names, organisation_id: ActsAsTenant.current_tenant.id).pluck(:id)
      return none if tag_ids.empty?
      return none if match_all && tag_ids.size < names.size

      base_query = joins(
        sanitize_sql_array([
                             "INNER JOIN taggings ON taggings.taggable_id = #{table_name}.id AND taggings.taggable_type = ?",
                             self.name
                           ])
      )

      if match_all && names.size > 1
        base_query
          .where(taggings: { tag_id: tag_ids })
          .select("#{table_name}.*")
          .group("#{table_name}.id")
          .having('COUNT(DISTINCT taggings.tag_id) >= ?', tag_ids.size)
      else
        base_query.where(taggings: { tag_id: tag_ids }).distinct
      end
    end

    def tag_counts
      Tag.select('tags.*, count(taggings.tag_id) as count')
         .joins(:taggings)
         .where(taggings: { taggable_type: name })
         .group('tags.id')
         .order('count DESC')
    end
  end
end
