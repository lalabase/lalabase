# frozen_string_literal: true

# app/services/actors/merge_tags.rb
#
# Merges one tag into another, from the management section "Tags"
# (Organisations::TagsController#merge): two spellings of one thing ("kunde-a"
# and "kunde a") stood as two tags. Every entry of the source gets the target,
# an entry that carries both keeps the target once, then the source is deleted.
# The tag rules of the saved filters that named the source name the target from
# then on (SmartFolders::TagRuleRename), in the same transaction.
#
# Refused: a tag into itself, and two tags of different organisations. Both rows
# are locked in one statement in the order of their ids (as
# Actors::MergeGlossaryTerms does), so two merges of the same pair at once wait
# for each other instead of deadlocking; a tag deleted in the meantime is refused
# as gone, and nothing moves. Rights are the caller's (TagPolicy#merge?, account
# admins); the caller resolves the target through the policy scope, never from a
# raw id. No activity per entry: the entries keep what they were tagged with,
# under the name the organisation agreed on.
module Actors
  class MergeTags < BaseActor
    ERROR_SCOPE = 'services.actors.merge_tags'

    def initialize(source:, target:, current_user:)
      super()
      @source = source
      @target = target
      @current_user = current_user
    end

    def record
      @target
    end

    def perform
      refuse(:same_tag) if @source.id == @target.id
      refuse(:other_organisation) unless @source.organisation_id == @target.organisation_id

      lock_both
      drop_double_taggings
      Tagging.where(tag_id: @source.id).update_all(tag_id: @target.id, updated_at: Time.current)
      SmartFolders::TagRuleRename.call(organisation: @target.organisation, from: @source.name, to: @target.name)
      @source.destroy!
    rescue ActiveRecord::RecordNotUnique
      # An entry got the target between dropping the doubles and moving the rest.
      refuse(:concurrent_change)
    end

    private

    attr_reader :current_user

    def refuse(code)
      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.#{code}"), code: code)
    end

    # One query, rows locked in the order of their ids; the locked rows replace
    # the given ones, so the merge works on what is stored now.
    def lock_both
      locked = Tag.where(id: [@source.id, @target.id]).order(:id).lock.index_by(&:id)
      @source = locked[@source.id]
      @target = locked[@target.id]
      refuse(:not_found) unless @source && @target
    end

    # An entry that carries both tags keeps the target's tagging; the source's
    # would be a second copy of it (index_taggings_uniqueness).
    def drop_double_taggings
      both = Tagging.where(tag_id: @target.id, taggable_id: Tagging.where(tag_id: @source.id).select(:taggable_id))
                    .pluck(:taggable_type, :taggable_id)
      both.group_by(&:first).each do |type, pairs|
        Tagging.where(tag_id: @source.id, taggable_type: type, taggable_id: pairs.map(&:last)).delete_all
      end
    end
  end
end
