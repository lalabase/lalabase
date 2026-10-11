# frozen_string_literal: true

# Types listed under Knowledge: notes and documents. Meetings live in their own area.
#
# A further knowledge type needs exactly ONE entry here:
# the UNION query arm (KnowledgeSearchQuery), type pills, row rendering and
# the smart-folder type mapping read exclusively from this registry.
#
# Fields per type:
#   model_name   class name; also taggings.taggable_type and
#                smart_folders.target_object_type
#   param_key    query param of the detail selection (e.g. "note_id")
#   access_area  Pundit area for area_access? checks
#   icon         Bootstrap-Icon class
#   label_key    i18n key of the type label (pills, badges)
#   title_sql    SQL expression of the title in the normalized UNION select
#   base_scope   lambda(project) -> relation of the query arm
#   search_scope lambda(scope, like_term, mode) -> relation with search condition
#   includes     eager loading when reloading the page objects per type
#   saved_views  false when knowledge neither lists nor saves views of this
#                type (optional, default true)
module Knowledge
  module TypeRegistry
    TYPES = {
      'note' => {
        model_name: 'Note',
        param_key: 'note_id',
        access_area: :notes,
        icon: 'bi-journal-text',
        label_key: 'views.organisations.knowledge.index.filter_notes',
        title_sql: 'notes.title',
        includes: %i[tags taggings],
        base_scope: ->(project) { project.notes },
        search_scope: lambda do |scope, like_term, mode|
          if mode == 'title_only'
            scope.where('notes.title ILIKE :s', s: like_term)
          else
            scope.where('notes.title ILIKE :s OR notes.plain_text_version ILIKE :s', s: like_term)
          end
        end
      },
      'document' => {
        model_name: 'Document',
        param_key: 'document_id',
        access_area: :documents,
        icon: 'bi-file-earmark-text',
        label_key: 'views.organisations.knowledge.index.filter_documents',
        title_sql: 'document_versions.title',
        includes: %i[current_version tags taggings],
        base_scope: lambda do |project|
          project.documents
                 .joins('INNER JOIN document_versions ON document_versions.id = documents.current_version_id')
        end,
        search_scope: lambda do |scope, like_term, mode|
          if mode == 'title_only'
            scope.where('document_versions.title ILIKE :s', s: like_term)
          else
            scope.where('document_versions.title ILIKE :s OR document_versions.plain_text_version ILIKE :s',
                        s: like_term)
          end
        end
      }
    }.freeze

    ALL_TYPE = 'all'

    module_function

    def keys
      TYPES.keys
    end

    def fetch(key)
      TYPES.fetch(key)
    end

    def key?(key)
      TYPES.key?(key)
    end

    # Type key for a model class name (e.g. 'Note' -> 'note')
    def key_for_model(model_name)
      TYPES.find { |_k, entry| entry[:model_name] == model_name }&.first
    end

    # Smart-folder target_object_type for a type-filter value (PE-B:
    # "Save as smart folder" follows the active type filter).
    # nil for a type without saved views in knowledge (the bar then saves nothing typed).
    def smart_folder_target_for(type_param)
      return 'All' if type_param.blank? || type_param == ALL_TYPE
      return 'All' unless key?(type_param)

      saved_view_target(type_param)
    end

    # target_object_type of the saved views knowledge lists and saves for a
    # type key; nil when the type has none (saved_views: false).
    def saved_view_target(key)
      entry = fetch(key)
      entry[:model_name] if entry.fetch(:saved_views, true)
    end

    # Type keys whose arm participates for a smart folder
    # (target_object_type acts as an additional type filter, PE-B).
    def keys_for_smart_folder_target(target_object_type)
      return keys if target_object_type.blank? || target_object_type == 'All'

      key = key_for_model(target_object_type)
      key ? [key] : []
    end
  end
end
