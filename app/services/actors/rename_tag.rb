# frozen_string_literal: true

# app/services/actors/rename_tag.rb
#
# A tag of the organisation gets another name, from the management section
# "Tags" (Organisations::TagsController#update). The name is stored in the one
# spelling of tag names (Tag.normalize_name) and follows the rules of a typed
# name (Tag.acceptable_new_name?). The name of another tag of the organisation
# is refused: two tags with one name are one tag, and that is a merge
# (Actors::MergeTags); the refusal says so, with the code :name_taken.
#
# The tag rules of the saved filters name a tag by its name. They are rewritten
# in the same transaction (SmartFolders::TagRuleRename), or a filter that showed
# the tag's entries would show none from then on. Rights are the caller's
# (TagPolicy#update?, account admins). The row is locked first, so the old name
# the rules are rewritten from is the stored one, not the one the form was
# rendered with.
module Actors
  class RenameTag < BaseActor
    ERROR_SCOPE = 'services.actors.rename_tag'

    def initialize(tag:, name:, current_user:)
      super()
      @tag = tag
      @name = Tag.normalize_name(name)
      @current_user = current_user
    end

    def record
      @tag
    end

    def perform
      @tag.lock!
      old_name = @tag.name
      return if @name == old_name

      validate_name!
      @tag.update!(name: @name)
      SmartFolders::TagRuleRename.call(organisation: @tag.organisation, from: old_name, to: @name)
    rescue ActiveRecord::RecordNotUnique
      # Another rename or a new tag took the name between the check and the write.
      refuse(:name_taken, name: @name)
    end

    private

    attr_reader :current_user

    def validate_name!
      problem = Tag.name_problem(@name)
      refuse(problem, count: Tag::MAX_NAME_LENGTH) if problem
      refuse(:name_taken, name: @name) if Tag.where(organisation_id: @tag.organisation_id, name: @name).where.not(id: @tag.id).exists?
    end

    def refuse(code, **values)
      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.#{code}", **values), code: code)
    end
  end
end
