# frozen_string_literal: true

# Polymorphic link index for the wiki (design D3).
#
#   source (note) ──▶ target (note | document)
#        │                 │
#        │                 └─ optional: the target may be hard-deleted (tombstone).
#        │                    target_title_snapshot is then shown instead of a 404.
#        └─ always present (the linking note).
#
# Built from the source's CANONICAL HTML (sgid attachments), not from Markdown.
# Dedup = DB unique index (one reference per target per source), matching the
# delete+insert rebuild on every save. Backlinks = where(target: x).
# == Schema Information
#
# Table name: references
#
#  id                    :uuid             not null, primary key
#  source_type           :string           not null
#  target_title_snapshot :string
#  target_type           :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  source_id             :uuid             not null
#  target_id             :uuid             not null
#
# Indexes
#
#  index_references_on_organisation_id    (organisation_id)
#  index_references_on_target_and_org     (target_type,target_id,organisation_id)
#  index_references_unique_source_target  (source_type,source_id,target_type,target_id) UNIQUE
#
class Reference < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :source, polymorphic: true
  belongs_to :target, polymorphic: true, optional: true

  validates :target_title_snapshot, length: { maximum: 255 }, allow_nil: true
  validate :forbid_self_reference

  # Backlinks to a target — displayed via target_title_snapshot (no N+1).
  scope :pointing_to, ->(record) { where(target_type: record.class.polymorphic_name, target_id: record.id) }

  private

  def forbid_self_reference
    return unless source_type == target_type && source_id == target_id

    errors.add(:base, :self_reference)
  end
end
