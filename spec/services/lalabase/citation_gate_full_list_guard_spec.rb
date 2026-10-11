# frozen_string_literal: true

require 'rails_helper'

# ============================================================================
# THE load-bearing regression guard for chat source attribution
# (chat_quellen_attribution_plan.md §3). READ THIS BEFORE TOUCHING THE FILTER.
#
# The `used: false` flag added by the attribution mechanism filters the ANZEIGE
# only (MessageComponent#visible_citations). The security-relevant consumers —
# the render-gate (redacted?/sourced_areas) and the gated-streaming trigger
# (Chatpost#content_bearing?) — MUST keep evaluating the FULL citation list and
# ignore the flag. Rationale: the model can DRAW ON an area's content (paraphrase,
# summarise, be steered by it) without CITING it as "used". If the gate stood on
# the used-subset, an answer could leak content from an area the viewer may not
# read, merely because the model marked that source `used: false`. So a
# `used: false` citation still redacts, still streams gated, still counts as an area.
#
# This guard exists so a future "optimisation" that routes areas_of / redacted? /
# content_bearing? through the filtered list fails HERE instead of silently
# opening a cross-area leak.
# ============================================================================
RSpec.describe 'Citation gate reads the FULL list, not the used-subset (attribution §3)', type: :component do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:chat)         { create(:chat, organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # An assistant answer whose ONLY content citation is flagged used: false — i.e.
  # the model said it did not use it, but it was still sent in the prompt context.
  def answer_with_unused_ticket
    chat.chatposts.create!(
      organisation: organisation, role: 'assistant',
      content: 'Der Stand zu Thema X ist geklaert.', model_used: 'gpt-x',
      source_citations: [{ 'type' => 'ticket', 'area' => 'tickets', 'id' => SecureRandom.uuid,
                           'project_id' => project.id, 'number' => 42, 'title' => 'GeheimerTitel',
                           'used' => false }]
    )
  end

  def viewer_without_ticket_access
    u = create(:user)
    create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    create(:project_permission, user: u, project: project, tickets_access: 'no_access')
    u
  end

  describe '(a) render-gate still redacts a used:false citation the viewer cannot read' do
    it 'redacts the answer AND hides the title even though the source is marked unused' do
      component = Neo::Chat::MessageComponent.new(chatpost: answer_with_unused_ticket,
                                                  current_user: viewer_without_ticket_access,
                                                  current_organisation: organisation)
      rendered = render_inline(component)

      expect(component.redacted?).to be(true)
      expect(rendered.to_html).not_to include('Der Stand zu Thema X') # prose gated
      expect(rendered.to_html).not_to include('GeheimerTitel')        # title not leaked
    end

    it 'derives the sourced area from the full list regardless of the flag' do
      component = Neo::Chat::MessageComponent.new(chatpost: answer_with_unused_ticket)
      expect(component.send(:sourced_areas)).to eq([:tickets])
    end
  end

  describe '(b) gated-streaming trigger counts a used:false content citation' do
    it 'Chatpost#content_bearing? is true with ONLY a used:false content citation' do
      post = chat.chatposts.create!(
        organisation: organisation, role: 'assistant', content: 'x',
        source_citations: [{ 'type' => 'note', 'area' => 'notes', 'id' => SecureRandom.uuid,
                             'project_id' => project.id, 'title' => 'N', 'used' => false }]
      )
      expect(post.content_bearing?).to be(true)
    end
  end

  describe '(c) Lalabase::Citations.areas_of ignores the used flag' do
    it 'returns the area of a used:false citation exactly as for a used:true one' do
      unused = [{ 'type' => 'ticket', 'area' => 'tickets', 'id' => 't1', 'used' => false }]
      used   = [{ 'type' => 'ticket', 'area' => 'tickets', 'id' => 't1', 'used' => true }]
      expect(Lalabase::Citations.areas_of(unused)).to eq([:tickets])
      expect(Lalabase::Citations.areas_of(unused)).to eq(Lalabase::Citations.areas_of(used))
    end
  end
end
