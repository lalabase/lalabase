# frozen_string_literal: true

require 'rails_helper'

# D10 (Gespräche Slice 7a): the account erasure path is a soft-delete, so the FK
# on_delete: :nullify on meeting_analyses NEVER fires. Without the explicit handling
# in PersonalDataErasure#erase_meeting_analyses! (reached from
# soft_delete_and_anonymize! on both paths), a PRIVATE analysis (readable only by
# its now-erased creator = dead PII) would survive, and PUBLISHED analyses would
# keep pointing at the erased account. This guards both on the ::User path in
# depth; the cross-path guard is spec/models/user_erasure_path_parity_spec.rb.
RSpec.describe User::DeletionLifecycle, type: :model do
  describe '#soft_delete_and_anonymize! and meeting analyses' do
    let(:organisation) { create(:organisation) }
    let(:project) { create(:project, organisation: organisation) }
    let(:user) { create(:user) }
    let(:other_user) { create(:user, organisation: organisation) }
    let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: other_user) }

    before do
      ActsAsTenant.current_tenant = organisation
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation), active: true)
    end

    after { ActsAsTenant.current_tenant = nil }

    it 'destroys the erased user\'s PRIVATE analyses (dead PII)' do
      private_analysis = create(:meeting_analysis, meeting: meeting, creator: user, is_private: true)

      expect { user.soft_delete_and_anonymize! }
        .to change { MeetingAnalysis.where(id: private_analysis.id).count }.from(1).to(0)
    end

    it 'keeps PUBLISHED analyses but nulls creator and visible_to_user' do
      published = create(:meeting_analysis, :published, meeting: meeting, creator: user,
                                                        prompt_title: 'Org-Inhalt', content: 'bleibt')

      user.soft_delete_and_anonymize!

      published.reload
      expect(published.creator_id).to be_nil
      expect(published.visible_to_user_id).to be_nil
      expect(published.prompt_title).to eq('Org-Inhalt')
      expect(published.content).to eq('bleibt')
    end

    it 'does not touch another user\'s analyses' do
      foreign = create(:meeting_analysis, meeting: meeting, creator: other_user, is_private: true)

      user.soft_delete_and_anonymize!

      foreign.reload
      expect(foreign.creator_id).to eq(other_user.id)
      expect(foreign.is_private).to be(true)
    end
  end
end
