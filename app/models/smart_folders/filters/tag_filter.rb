# frozen_string_literal: true

# app/models/smart_folders/filters/tag_filter.rb
module SmartFolders
  module Filters
    # Filter for tags via the polymorphic Tagging relationship.
    # Supports operators: has, has_any_of, not_has, has_all_of
    class TagFilter < BaseFilter
      include SmartFolders::Operators

      def apply(query, _item_type)
        return query unless taggable_model?(query.model)

        tag_names = parse_tag_names(rule.value)
        return handle_empty_tags(query) if tag_names.empty?

        tag_ids = find_tag_ids(tag_names)
        return handle_no_matching_tags(query) if tag_ids.empty?

        # has_all_of: If not all of the requested tags exist in the DB,
        # no ticket can have all of them → immediately none
        return query.none if rule.operator == HAS_ALL_OF && tag_ids.size < tag_names.size

        apply_operator(query, tag_ids)
      end

      private

      def taggable_model?(model)
        supported = model.reflect_on_association(:taggings) && model.reflect_on_association(:tags)
        Rails.logger.warn "Model #{model.name} does not support tagging. Skipping tag filter for rule #{rule.id}." unless supported
        supported
      end

      def parse_tag_names(value)
        return [] if value.blank?

        value.to_s.split(',').map(&:strip).reject(&:blank?).uniq
      end

      # Memoized on the Rule: for target 'All' the QueryBuilder runs across
      # multiple model arms and re-instantiates the filter per arm — but the
      # Rule instance (and thus the org-wide tag lookup) stays identical.
      def find_tag_ids(tag_names)
        rule.cached_tag_ids ||= Tag.where(name: tag_names, organisation_id: ActsAsTenant.current_tenant.id).pluck(:id)
      end

      def handle_empty_tags(query)
        case rule.operator
        when HAS, HAS_ANY_OF, HAS_ALL_OF
          query.none
        else
          query
        end
      end

      def handle_no_matching_tags(query)
        rule.operator == NOT_HAS ? query : query.none
      end

      def apply_operator(query, tag_ids)
        taggable_type = query.model.name

        case rule.operator
        when HAS, HAS_ANY_OF
          query.where(id: tagged_ids_subquery(tag_ids, taggable_type))
        when NOT_HAS
          query.where.not(id: tagged_ids_subquery(tag_ids, taggable_type))
        when HAS_ALL_OF
          query.where(id: ids_with_all_tags_subquery(tag_ids, taggable_type))
        else
          Rails.logger.warn "Unsupported tag operator '#{rule.operator}' for rule #{rule.id}."
          query
        end
      end

      def tagged_ids_subquery(tag_ids, taggable_type)
        Tagging.where(tag_id: tag_ids, taggable_type: taggable_type).select(:taggable_id)
      end

      # Subquery instead of pluck: no separate roundtrip per model arm
      def ids_with_all_tags_subquery(tag_ids, taggable_type)
        Tagging.where(tag_id: tag_ids, taggable_type: taggable_type)
               .group(:taggable_id)
               .having('COUNT(DISTINCT tag_id) = ?', tag_ids.size)
               .select(:taggable_id)
      end
    end
  end
end
