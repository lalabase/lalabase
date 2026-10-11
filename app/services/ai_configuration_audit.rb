# frozen_string_literal: true

# app/services/ai_configuration_audit.rb
#
# The protocol row for "somebody changed this organisation's OWN AI access"
# (doc/ki_bereich_navigation_plan.md E5/L13, third of the three write sites).
#
# Extracted at the SECOND caller rather than CLAUDE.md's third, and the reason is that
# the two callers are the two halves of one decision: Actors::SaveAiConfiguration writes
# an access, Actors::RemoveAiConfiguration takes it away. A reader of the protocol has to
# be able to line those up — same verb, same payload keys, same "only when something
# moved" rule — and two hand-maintained copies of that shape is precisely how the
# removal row ends up missing the field that would have explained the entry above it.
#
# It also concentrates the three properties an Activity needs here, which were measured
# rather than guessed (P4e, then S0):
#   * skip_notifications — an Activity is not a quiet audit row. after_create_commit reaches
#     OutboxEvent → FanoutService, and derive_event_type falls back to system_message for
#     an unknown key, which would mail the whole organisation about a settings change.
#   * with_tenant — acts_as_tenant OVERWRITES the passed organisation from
#     current_tenant in a before_validation on :create, so an audit row whose mandant
#     depends on ambient state is not an audit row.
#   * only when something MOVED — "nothing happened" in an audit trail cannot be told
#     apart from a real entry afterwards.
#
# Entry point: .call
class AiConfigurationAudit
  # The columns that ARE the organisation's own AI access — the audit's subject and,
  # deliberately, the same list Actors::SaveAiConfiguration may write and
  # Actors::RemoveAiConfiguration clears. One list, because the two questions have one
  # answer: a writable column missing here is a change nobody can reconstruct, and an
  # audited column nothing writes is a payload key frozen at its initial value.
  COLUMNS = %i[ai_provider ai_access_token ai_organization_id ai_api_base preferred_chat_model].freeze

  # The verb this write files under. Its own, next to ai_activated and
  # ai_package_selected: switching the provider or the token of an organisation's own
  # access is a decision about the PROCESSOR, distinct from the legal-basis decision
  # (the on/off switch) and from picking a curated package.
  ACTION = AiProtocolActions::CONFIGURATION_CHANGED

  # Reads the five columns off a record — the shape #call expects on both sides.
  # String keys, because that is what ActiveRecord::Base#slice returns and what the
  # payload below is built from; a symbol/string mismatch between the two sides would
  # make every comparison report a change.
  def self.snapshot(organisation)
    organisation.slice(*COLUMNS.map(&:to_s))
  end

  def self.call(**kwargs)
    new(**kwargs).call
  end

  # @param before [Hash] .snapshot taken before the write
  # @param after [Hash] .snapshot taken after it
  def initialize(organisation:, current_user:, before:, after:)
    @organisation = organisation
    @current_user = current_user
    @before = before
    @after = after
  end

  # @return [Activity, nil] nil when nothing moved
  def call
    return nil if @before == @after

    ActsAsTenant.with_tenant(@organisation) do
      Activity.create!(organisation: @organisation, actor: @current_user,
                       trackable: @organisation, action: ACTION,
                       parameters: parameters,
                       skip_notifications: true)
    end
  end

  private

  # The TOKEN is never part of the payload — only whether one is present and whether it
  # moved. An audit row carrying the secret would be a second, unencrypted copy of it in
  # a table built to be read.
  #
  # The endpoint and the organisation id ARE part of it, and they are the reason this
  # payload is wider than the provider alone: "where did our data start going, and when"
  # is the question asked after an incident, and a row naming only the provider cannot
  # answer it for an openai_compatible access, where the provider stays the same and the
  # URL is the whole difference. `token_rotated` for the same reason — own_token_present
  # is true on both sides of a rotation, so without it a key swap is indistinguishable
  # from a write that touched nothing.
  def parameters
    {
      'from_provider' => @before['ai_provider'],
      'to_provider' => @after['ai_provider'],
      'from_model' => @before['preferred_chat_model'],
      'to_model' => @after['preferred_chat_model'],
      'from_api_base' => @before['ai_api_base'],
      'to_api_base' => @after['ai_api_base'],
      'from_organization_id' => @before['ai_organization_id'],
      'to_organization_id' => @after['ai_organization_id'],
      'own_token_present' => @after['ai_access_token'].present?,
      'token_rotated' => @before['ai_access_token'] != @after['ai_access_token']
    }
  end
end
