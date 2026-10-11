# frozen_string_literal: true

# app/services/actors/set_chat_style.rb
#
# Sets ONE dimension of the requesting user's persistent chat answer-style level
# to an absolute value (the style pills under the composer). Pure state: this
# actor deliberately enqueues NO job and triggers NO answer — a setting below the
# message field reads as "for what I write next", so regenerating the previous
# answer off it would be ambiguous (and outright contradictory with text already
# typed in the composer). Re-running an existing answer in the new style is the
# separate, explicit "regenerate" action on the answer itself
# (Actors::RegenerateChatpost).
#
# Domain failures use precise codes (#103 pattern): :invalid_dimension /
# :invalid_level — the controller maps both to 422.

module Actors
  class SetChatStyle < BaseActor
    ERROR_SCOPE = 'services.actors.set_chat_style'

    # organisation: explicit kwarg — the actor must not depend on the ambient
    # tenant for the preference row it writes.
    def initialize(dimension:, level:, current_user:, organisation:)
      super()
      @dimension = dimension.to_s
      @level = Integer(level, exception: false)
      @current_user = current_user
      @organisation = organisation
    end

    # The preference row (nil before the write — safe_record covers failures).
    def record
      @preference
    end

    def perform
      reject!(:invalid_dimension) unless ChatStylePreference::DIMENSIONS.include?(@dimension)
      reject!(:invalid_level) unless ChatStylePreference::LEVELS.include?(@level)

      @preference = ChatStylePreference.set_for!(
        user: @current_user, organisation: @organisation, dimension: @dimension, level: @level
      )
    end

    private

    def reject!(code)
      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.#{code}"), code: code)
    end
  end
end
