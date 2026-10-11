# frozen_string_literal: true

require 'rails_helper'

# AnalysisPrompt — the org-wide prompt library (Slice 7a). Intent: prove the DoS
# byte cap and that deleting a prompt leaves existing analyses intact (FK nullify +
# frozen snapshot), which is what lets the library be curated without disturbing
# past work.
RSpec.describe AnalysisPrompt do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'validations' do
    it 'requires a title and prompt_text' do
      prompt = build(:analysis_prompt, title: nil, prompt_text: nil)
      expect(prompt).to be_invalid
      expect(prompt.errors[:title]).to be_present
      expect(prompt.errors[:prompt_text]).to be_present
    end

    it 'rejects a prompt_text over the byte cap' do
      prompt = build(:analysis_prompt, prompt_text: 'a' * (described_class::MAX_PROMPT_BYTES + 1))
      expect(prompt).to be_invalid
      expect(prompt.errors[:prompt_text]).to be_present
    end
  end

  describe 'deletion (snapshot survives)' do
    it 'nullifies analysis_prompt_id on existing analyses but keeps the snapshot' do
      prompt = create(:analysis_prompt, organisation: organisation, creator: user)
      analysis = create(:meeting_analysis, meeting: meeting, creator: user,
                                           analysis_prompt: prompt, prompt_title: 'Fester Titel',
                                           prompt_snapshot: 'Fester Prompt-Text')

      prompt.destroy

      analysis.reload
      expect(analysis.analysis_prompt_id).to be_nil
      expect(analysis.prompt_title).to eq('Fester Titel')
      expect(analysis.prompt_snapshot).to eq('Fester Prompt-Text')
    end
  end
end
