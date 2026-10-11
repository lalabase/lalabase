# frozen_string_literal: true

# Shared date-window semantics for records that are valid within a period:
# price lists and account discounts (doc/billing_preisliste_rabatt_plan.md D4).
# Both need the identical rule -- a window with an optionally open end that must
# not overlap another window within the same key, plus "what applies on date X".
# Two concrete callers in the same phase, not a speculative abstraction.
#
# ends_on is INCLUSIVE: the last day on which the record applies (D2). Every
# boundary query in the app reads
#   starts_on <= date AND (ends_on IS NULL OR ends_on >= date)
# Thinking in half-open daterange('[)') semantics silently shifts the last day.
#
# DELIBERATELY LIMITED to window semantics (review constraint, D4). Mutability
# rules ("a price that already applies is not edited") and the replacement logic
# live in the actors, not here -- putting them in would accumulate special cases
# for two models whose rules differ.
#
# The no-overlap check is app-level, a conscious decision (D4): the only write
# path is a single operator in the admin backend. The harder variant would be a
# PostgreSQL EXCLUDE constraint over daterange + btree_gist, which also pins the
# inclusive semantics in the DB -- retrofittable once more than one person
# maintains prices.
module EffectiveDating
  extend ActiveSupport::Concern

  class ScopeNotConfiguredError < StandardError; end

  included do
    # nil (not []) is the "never configured" marker -- see effective_dating_scope.
    class_attribute :effective_dating_scope_columns, instance_writer: false, default: nil

    validates :starts_on, presence: true
    validate :ends_on_not_before_starts_on
    validate :period_must_not_overlap

    # Rows applying on `date`. Inclusive on both ends; NULL ends_on is open.
    scope :effective_on, lambda { |date|
      where(arel_table[:starts_on].lteq(date))
        .where(arel_table[:ends_on].gteq(date).or(arel_table[:ends_on].eq(nil)))
    }
  end

  class_methods do
    # Columns that scope the no-overlap rule: [:plan_key] for price lists,
    # [:account_id] for discounts. Call with no arguments to declare a
    # deliberately GLOBAL window (no two rows in the whole table may overlap).
    def effective_dating_scope(*columns)
      self.effective_dating_scope_columns = columns.map(&:to_sym).freeze
    end
  end

  def effective_on?(date = Date.current)
    return false if starts_on.blank?

    starts_on <= date && (ends_on.nil? || ends_on >= date)
  end

  private

  def ends_on_not_before_starts_on
    return if starts_on.blank? || ends_on.blank?
    return if ends_on >= starts_on

    errors.add(:ends_on, :ends_before_starts_on)
  end

  def period_must_not_overlap
    return if starts_on.blank?
    return if overlapping_records.none?

    errors.add(:starts_on, :overlapping_period)
  end

  # Two inclusive windows [a1, b1] and [a2, b2] (b may be NULL = open) overlap
  # iff a1 <= b2 and a2 <= b1. Both halves below are written from the OTHER
  # row's perspective; a NULL end on either side drops its half of the test,
  # because an open window extends past every later date.
  def overlapping_records
    relation = self.class.where(effective_dating_scope_conditions)
    relation = relation.where.not(id: id) if persisted?
    relation = relation.where(
      self.class.arel_table[:ends_on].gteq(starts_on)
        .or(self.class.arel_table[:ends_on].eq(nil))
    )
    return relation if ends_on.blank?

    relation.where(self.class.arel_table[:starts_on].lteq(ends_on))
  end

  def effective_dating_scope_conditions
    columns = self.class.effective_dating_scope_columns
    # A model that includes the concern but never declares its scope would
    # silently get a table-wide no-overlap rule -- wrong for every caller we
    # have, and invisible until two unrelated rows collide in production.
    raise ScopeNotConfiguredError, "#{self.class.name} must declare effective_dating_scope" if columns.nil?

    columns.index_with { |column| self[column] }
  end
end
