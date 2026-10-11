# frozen_string_literal: true

# What: Request spec for the ticket "Ask AI" path under the GDPR AI opt-in.
# Type: Request spec — functional block: post creation + gated AI side-path.
# Why (philosophy): This is the LEGACY seam (Organisation#ai_client_with_usage_
#   tracking, not the Llm::Factory) — the audit's gate must hold here too. The
#   contract is subtle: the user's own post MUST still be saved (local data),
#   only the AI reply is refused, and the user learns why via the dedicated
#   flash — not the misleading generic "AI failed" fallback copy.
# Contract: POST posts with ask_ai=1 on a disabled org → exactly one new post
#   (the user's), no AI post, shared.ai.disabled_member_hint, no 500.

require 'rails_helper'

RSpec.describe 'Organisations::Posts ask_ai (GDPR AI opt-in)', type: :request do
  let(:organisation) { create(:organisation, :ai_disabled) }
  let(:user) { create(:user) }
  let(:role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Current.user = user
  end

  after { Current.reset }

  def post_count
    ActsAsTenant.with_tenant(organisation) { ticket.posts.count }
  end

  it 'saves the user post, refuses the AI reply and explains why (no 500, no generic fallback copy)' do
    expect do
      post organisation_project_ticket_posts_path(organisation, project, ticket),
           params: { post: { content: 'Please summarise this' }, ask_ai: '1' }
    end.to change { post_count }.by(1) # ONLY the user's post — no AI answer post

    expect(response).not_to have_http_status(:internal_server_error)
    expect(flash[:alert]).to eq(I18n.t('shared.ai.disabled_member_hint'))
  end
end
