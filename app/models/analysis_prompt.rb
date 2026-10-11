# frozen_string_literal: true

# Slice 7a: an org-wide prompt library entry for meeting analyses (Gespräche).
# Prompts are a shared org asset managed inline from the analysis form (E20) — the
# analyses are the private thing, not the prompts. The creator is authoring
# metadata and nullifies on user deletion; each MeetingAnalysis additionally keeps
# a frozen title/text snapshot, so editing or deleting a prompt never disturbs
# existing analyses.
# == Schema Information
#
# Table name: analysis_prompts
#
#  id              :uuid             not null, primary key
#  prompt_text     :text             not null
#  title           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  creator_id      :uuid
#  organisation_id :uuid             not null
#
class AnalysisPrompt < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :creator, class_name: 'User', optional: true
  # A deleted prompt leaves its analyses intact — the FK nullifies analysis_prompt_id
  # (DB on_delete: :nullify mirrors this); the analysis keeps its snapshot.
  has_many :meeting_analyses, dependent: :nullify

  # DoS guard (Meeting::MAX_CONTENT_BYTES pattern): a prompt is short instruction
  # text, not a document. 10 KB is generous and bounds the LLM prompt cost.
  MAX_PROMPT_BYTES = 10.kilobytes

  validates :title, presence: true
  validates :prompt_text, presence: true
  validate :prompt_text_within_byte_limit

  private

  def prompt_text_within_byte_limit
    return if prompt_text.blank? || prompt_text.bytesize <= MAX_PROMPT_BYTES

    errors.add(:prompt_text, :too_large)
  end
end
