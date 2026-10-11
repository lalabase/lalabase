# frozen_string_literal: true

# GDPR org-level AI opt-in guard (audit 2026-07-03). ONE implementation for every
# controller whose actions would enqueue an LLM call -- extracted from
# ProjectController in S3a T2 because the rule is ORG-level, and the assistant
# controllers have no project (and must not drag the project machinery in just
# for this guard). Controllers opt in via
# `before_action :ensure_ai_enabled, only: [...]` and say where to land.
module AiFeatureGate
  extend ActiveSupport::Concern

  private

  def ensure_ai_enabled
    return if @current_organisation.ai_enabled?

    redirect_to ai_disabled_redirect_path, alert: t('shared.ai.disabled_member_hint')
  end

  # Where a blocked AI action should send the user. No default: a controller
  # adding the guard must consciously pick its landing page (chat show vs.
  # chats index look very different from the user's point of view).
  def ai_disabled_redirect_path
    raise NotImplementedError, "#{self.class.name} uses ensure_ai_enabled but does not define ai_disabled_redirect_path"
  end
end
