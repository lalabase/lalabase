# frozen_string_literal: true

require 'rails_helper'

# The references of a conversation that does not exist yet (the first message
# creates it). Since the writing-zone plan (2026-11-19) they read like the
# context row of a running conversation: "Thema:" once in front, quiet pills.
# The pills are added by assistant_panel_controller from the template below, so
# whether the label shows is a CSS question (`:has`), pinned here as markup.
RSpec.describe Neo::Chat::DraftReferencesComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def render_drafts
    render_inline(described_class.new(chat: Chat.new(organisation: organisation, user: user), current_user: user))
  end

  it 'names the topic once, hidden until the first pill is there' do
    render_drafts

    label = page.find('span', text: I18n.t('views.organisations.assistant_panels.reference.label'), visible: :all)
    expect(label[:class].split).to include('hidden', 'group-has-[[data-draft-reference]]/drafts:inline')
    expect(page.find('[data-assistant-panel-target="draftReferences"]', visible: :all)[:class]).to include('group/drafts')
  end

  it 'keeps the label out of the pill template, and the pill quiet' do
    render_drafts

    # Read from the raw markup: Nokogiri keeps a <template>'s content out of the tree.
    pill_html = rendered_content[%r{<template data-assistant-panel-target="draftReferenceTemplate">(.*?)</template>}m, 1]
    expect(pill_html).not_to include(I18n.t('views.organisations.assistant_panels.reference.label'))
    expect(pill_html).not_to include('border-ink')
    expect(pill_html).to include('data-draft-label')
  end
end
