# frozen_string_literal: true

# The tag rules of an organisation's saved filters, rewritten for a tag that got
# another name (Actors::RenameTag) or went into another tag (Actors::MergeTags).
# A rule names its tags by name, not by id (field 'tag', value "a,b", read by
# SmartFolders::Filters::TagFilter), so without this a filter that showed the
# entries of a tag would show nothing from then on, or everything where it
# excluded them.
#
# Every name of a rule is compared in the one spelling of tag names
# (Tag.normalize_name). A name that becomes a second copy of one the rule holds
# already is dropped: "a,b" with a merged into b reads "b". The rules are written
# with update_columns: the rewrite must not fail on a rule that a validation of
# today would refuse for a reason of its own, and the value shown of a tag rule
# is its value (SmartFolderRule#resolve_display_value, value type text). Runs in
# the transaction of its caller.
#
# Entry point: call
module SmartFolders
  class TagRuleRename
    FIELD = 'tag'

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(organisation:, from:, to:)
      @organisation = organisation
      @from = Tag.normalize_name(from)
      @to = Tag.normalize_name(to)
    end

    # => the number of rules rewritten. Read under the organisation as tenant:
    # SmartFolder is tenant-scoped, and the organisation is the one asked about.
    def call
      return 0 if @from == @to

      ActsAsTenant.with_tenant(@organisation) do
        candidates.sum do |rule|
          value = renamed(rule.value)
          next 0 if value == rule.value

          rule.update_columns(value: value, display_value: value, updated_at: Time.current)
          1
        end
      end
    end

    private

    # The rules that may name the tag: ILIKE narrows, #renamed decides.
    def candidates
      SmartFolderRule.joins(smart_folder_rule_group: :smart_folder)
                     .where(field: FIELD, smart_folders: { organisation_id: @organisation.id })
                     .where('smart_folder_rules.value ILIKE ?', "%#{SmartFolderRule.sanitize_sql_like(@from)}%")
    end

    def renamed(value)
      names = value.to_s.split(Tag::NAME_SEPARATOR).map(&:strip).reject(&:blank?)
      return value unless names.any? { |name| Tag.normalize_name(name) == @from }

      names.map { |name| Tag.normalize_name(name) == @from ? @to : name }
           .uniq { |name| Tag.normalize_name(name) }
           .join(Tag::NAME_SEPARATOR)
    end
  end
end
