# frozen_string_literal: true

module Actors
  # Publishes ONE price level together with its complete seat ladder
  # (doc/billing_preisliste_rabatt_plan.md D9/§6). Non-trivial by every measure
  # of the seam rule: up to 15 rows, two ladder invariants, and the predecessor
  # has to be closed in the same transaction -- a half-published level would be
  # a price nobody decided on.
  #
  # Called only from the operator engine (gboyke/lalabase-operator, S3.2): its
  # price list controller and Subscriptions::PriceListSeed. The actor stays in
  # the core because the core owns the rule (doc/oss_core_split_plan.md 5.6:
  # operator controllers stay thin, the rules live here).
  #
  # NO current_user, deliberately (D8): the operator here is a Beuser from the
  # admin session, not a User, so Current.user must stay untouched -- it feeds
  # the Activity chain, which expects a real User. The audit trail is the
  # created_by_email snapshot on the row instead.
  #
  # ORDER MATTERS: the predecessor is clipped BEFORE the new level is created.
  # The other way round, EffectiveDating's no-overlap validation would reject
  # the new level against the still-open predecessor.
  class PublishPriceList < BaseActor
    def initialize(plan_key:, starts_on:, tiers:, currency: 'EUR', note: nil, created_by_email: nil)
      super()
      @plan_key = plan_key
      @starts_on = starts_on
      @tiers = tiers.map(&:symbolize_keys)
      @currency = currency
      @note = note
      @created_by_email = created_by_email
    end

    def perform
      reject_empty_ladder!
      reject_broken_ladder!
      close_predecessor!
      create_price_list!
    end

    def record
      @price_list
    end

    private

    def reject_empty_ladder!
      return if @tiers.any?

      raise ActorError.new(I18n.t('services.actors.publish_price_list.no_tiers'), code: :no_tiers)
    end

    # Checked before anything is written, so a broken ladder is refused rather
    # than rolled back -- and the operator sees every defect at once.
    def reject_broken_ladder!
      errors = Subscriptions::LadderValidator.errors_for(@tiers)
      return if errors.empty?

      messages = errors.map { |error| message_for(error) }
      raise ActorError.new(messages, code: :invalid_ladder)
    end

    # The interval arrives as its raw registry key ('monthly'); left as-is it
    # opened a German sentence with a bare English word. Translating it here
    # keeps the validator producing data and this class producing sentences.
    def message_for(error)
      interval_label = I18n.t("admin.billing_interval.#{error[:billing_interval]}",
                              default: error[:billing_interval].to_s)
      I18n.t("services.actors.publish_price_list.#{error[:key]}",
             **error.except(:key), billing_interval: interval_label)
    end

    # The level in force on the day before the new one starts keeps running
    # until exactly that day. An open end (ends_on nil) or one reaching into the
    # new period is pulled back; a predecessor that already ends earlier is left
    # alone.
    def close_predecessor!
      last_day = @starts_on - 1.day
      predecessor = Subscriptions::PriceLookup.current(plan_key: @plan_key, on: last_day)
      return if predecessor.nil?
      return if predecessor.ends_on.present? && predecessor.ends_on <= last_day

      predecessor.update!(ends_on: last_day)
    end

    def create_price_list!
      @price_list = PriceList.create!(
        plan_key: @plan_key, starts_on: @starts_on, currency: @currency,
        note: @note, created_by_email: @created_by_email
      )
      @tiers.each { |attrs| @price_list.tiers.create!(attrs) }
    end
  end
end
