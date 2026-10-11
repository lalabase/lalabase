# frozen_string_literal: true

# A participant of a Meeting (Gespräche), Slice 1b. May link to an internal User
# (user_id) or be a pure external name (user_id nil). display_name is a snapshot:
# when the linked user is deleted, user_id becomes NULL (FK on_delete: :nullify)
# but the name survives so the attendance history stays intact.
#
# normalized_name is the dedup/search key: the DB uniquely constrains
# (meeting_id, normalized_name), and Slice 1c searches "all meetings with person X"
# by it. The normalization rule lives in .normalize_name and is mirrored in
# app/javascript/lib/meetings/name_normalizer.js — a contract spec keeps both
# implementations pinned to spec/fixtures/name_normalization_cases.json.
# == Schema Information
#
# Table name: meeting_participants
#
#  id              :uuid             not null, primary key
#  display_name    :string           not null
#  normalized_name :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  meeting_id      :uuid             not null
#  organisation_id :uuid             not null
#  user_id         :uuid
#
# Indexes
#
#  idx_on_organisation_id_normalized_name_5eadc4a5e5             (organisation_id,normalized_name)
#  index_meeting_participants_on_meeting_id_and_normalized_name  (meeting_id,normalized_name) UNIQUE
#  index_meeting_participants_on_meeting_id_and_user_id          (meeting_id,user_id) UNIQUE WHERE (user_id IS NOT NULL)
#  index_meeting_participants_on_user_id                         (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (meeting_id => meetings.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#
class MeetingParticipant < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :meeting
  belongs_to :user, optional: true

  before_validation :assign_normalized_name

  validates :display_name, presence: true
  validates :normalized_name, presence: true
  # Clean form errors for the two dup shapes the DB indexes guard against. The
  # actor pre-checks the desired set too, but these keep the model honest when
  # rows are built directly (specs, console).
  validates :normalized_name, uniqueness: { scope: :meeting_id }, allow_blank: true
  validates :user_id, uniqueness: { scope: :meeting_id }, allow_nil: true

  # External (name-only) participants in the given projects — the ONE definition of
  # "an external participation eligible to be claimed", shared by the claim matcher
  # (counts them) and the claim actor (links them). Callers pass an already
  # access-scoped project_ids list.
  scope :external_in_projects, lambda { |project_ids|
    where(user_id: nil).joins(:meeting).where(meetings: { project_id: project_ids })
  }

  # Normalization contract (mirrored in name_normalizer.js): NFC -> trim + collapse
  # whitespace -> downcase -> umlaut transliteration. Accents other than umlauts
  # are only downcased. Pure function so the contract spec can call it directly.
  def self.normalize_name(value)
    return '' if value.nil?

    s = value.to_s.unicode_normalize(:nfc)
    s = s.strip.gsub(/\s+/, ' ')
    s = s.downcase
    s.gsub('ä', 'ae').gsub('ö', 'oe').gsub('ü', 'ue').gsub('ß', 'ss')
  end

  # Distinct people across a set of meetings, deduped by normalized_name with the
  # newest spelling winning (created_at desc, first seen kept), shaped as
  # [display_name, normalized_name] pairs sorted by label — exactly what the
  # participant filter's select_tag options want. Powers both the project index
  # and the org-wide index (Slice 1c) filter dropdown; the caller passes the
  # already-scoped meeting relation, so the option list never leaks a name from a
  # meeting the user cannot read.
  def self.distinct_names_for_meetings(meeting_scope)
    rows = where(meeting_id: meeting_scope.select(:id))
           .order(created_at: :desc)
           .pluck(:normalized_name, :display_name)
    latest = {}
    rows.each { |normalized, display| latest[normalized] ||= display }
    latest.map { |normalized, display| [display, normalized] }.sort_by { |label, _| label.downcase }
  end

  private

  def assign_normalized_name
    self.display_name = display_name.to_s.strip.gsub(/\s+/, ' ') if display_name.present?
    self.normalized_name = self.class.normalize_name(display_name)
  end
end
