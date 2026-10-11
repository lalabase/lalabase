# frozen_string_literal: true

# app/services/actors/save_overview_layout.rb
#
# Single write path behind the organisation-overview editor: persists the
# parsed layout to the target the `scope` kwarg selects — the acting user's own
# row or the shared org default (user_id NULL); authorization stays in the
# controller. Saving the default also clears the acting user's OWN personal
# override (the cascade prefers a personal row, so a leftover override would
# hide the fresh default); other members' rows are never touched. Both scopes
# run inside the BaseActor transaction.
#
# On failure #record returns a rebuilt, re-validated config of the CURRENT
# context carrying the rejected layout — exactly what the controller's 422
# turbo-frame re-render needs (A2 contract, see Dashboards::Configurable).
#
# Deliberately mirrors Actors::SaveDashboardLayout (the project-dashboard
# surface). The surfaces genuinely diverge (one org-level surface here vs.
# project cascade + cross-project _all scopes there), so the duplication is
# intentional — unify when a third dashboard surface appears.

module Actors
  class SaveOverviewLayout < BaseActor
    def initialize(organisation:, current_user:, layout:, scope:)
      super()
      @organisation = organisation
      @current_user = current_user
      @layout = layout
      @scope = scope
      @saved_config = nil
    end

    # Success: the row just written. Failure: a fresh, re-validated config
    # carrying the rejected layout (A2).
    def record
      @saved_config || rebuilt_config
    end

    def perform
      case @scope
      when 'personal'
        save_config(user: @current_user)
      when 'default'
        save_config(user: nil)
        clear_personal_override
      else
        # A scope outside the controller whitelist is a programming error, not a
        # domain failure — crash loudly (dev/test re-raise via BaseActor).
        raise ArgumentError, "Unknown save scope: #{@scope.inspect}"
      end
    rescue ActiveRecord::RecordNotUnique
      # Parallel first-time save of the org default: the partial unique index
      # (WHERE user_id IS NULL) fires before the model validation can see the
      # other row. Map it to a domain failure instead of a 500; no retry
      # (admin-only surface, practically never concurrent).
      raise ActorError.new(
        I18n.t('activerecord.errors.models.overview_configuration.attributes.user_id.org_default_exists'),
        code: :conflict
      )
    end

    private

    def save_config(user:)
      config = OverviewConfiguration.find_or_initialize_by(user: user, organisation: @organisation)
      config.layout = @layout
      config.save!
      @saved_config = config
    end

    # Drops the acting user's OWN personal overview so the default they just
    # saved is what they see; other members keep theirs.
    def clear_personal_override
      OverviewConfiguration.where(user: @current_user, organisation: @organisation).delete_all
    end

    # The 422 frame re-render needs a config of the current context carrying the
    # rejected layout WITH populated errors — re-validate explicitly, because
    # the failed save may have happened on the default row, not the personal one.
    def rebuilt_config
      config = OverviewConfiguration.for_user_organisation(@current_user, @organisation)
      config.layout = @layout
      config.valid?
      config
    end
  end
end
