# frozen_string_literal: true

# == Schema Information
#
# Table name: meeting_analyses
#
#  id                       :uuid             not null, primary key
#  content                  :text             default(""), not null
#  creation_error           :text             default(""), not null
#  creation_flag            :boolean          default(FALSE), not null
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  include_in_search        :boolean          default(FALSE), not null
#  is_private               :boolean          default(TRUE), not null
#  prompt_snapshot          :text             not null
#  prompt_title             :string           not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  analysis_prompt_id       :uuid
#  creator_id               :uuid
#  meeting_id               :uuid             not null
#  organisation_id          :uuid             not null
#  visible_to_user_id       :uuid
#
FactoryBot.define do
  factory :meeting_analysis do
    association :meeting
    # Keep org + creator consistent with the meeting by default; specs override the
    # creator to test cross-creator visibility. visible_to_user is left to the model
    # callback (private ⇒ creator).
    organisation { meeting.organisation }
    creator { meeting.creator }
    prompt_title { 'Entscheidungs-Protokoll' }
    prompt_snapshot { 'Fasse die getroffenen Entscheidungen und offenen Punkte zusammen.' }
    content { 'Es wurde beschlossen, mit Q3 zu starten.' }
    is_private { true }

    trait :published do
      is_private { false }
    end
  end
end
