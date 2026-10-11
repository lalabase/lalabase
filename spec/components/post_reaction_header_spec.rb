# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Post reaction header', type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, organisation: organisation, project: project) }
  let(:post_record) { create(:post, organisation: organisation, ticket: ticket, user: user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, organisation: organisation, user: user, role: role, active: true)
  end
  after { ActsAsTenant.current_tenant = nil }

  def render_post(**options)
    render_inline(NeoPostComponent.new(post: post_record.reload, current_user: user,
                                       current_organisation: organisation, **options))
  end

  it 'has no empty chip or reaction row, only the corner trigger and five menu choices' do
    render_post

    expect(page).to have_no_css('.post-reaction-chip')
    expect(page).to have_css('.post-head .post-reaction-trigger', count: 1)
    expect(page).to have_no_css('.post-reaction-trigger .bi-plus')
    expect(page).to have_css('.post-head .post-edit-button')
    expect(page).to have_css('.post-reaction-menu[popover="manual"] .post-reaction-option', count: 5, visible: :all)
    expect(page).to have_no_css('[data-post-reactions-for].mt-2')
  end

  it 'places own and other reactions after the time with a neutral selected state' do
    create(:post_reaction, organisation: organisation, post: post_record, user: user, emoji: '✅')
    create(:post_reaction, organisation: organisation, post: post_record, user: create(:user), emoji: '👍')
    render_post

    expect(page).to have_css('.post-head .post-meta + .post-reactions .post-reaction-chip', count: 2)
    expect(page).to have_css('.post-reaction-chip--selected[aria-pressed="true"]', text: '✅')
    expect(page).to have_css('.post-reaction-chip:not(.post-reaction-chip--selected)[aria-pressed="false"]', text: '👍')
    expect(page).to have_css('[data-post-reaction-tooltip-text-value="Du"]')
    expect(page).to have_no_css('[data-post-reactions-for] [class*="green-"]')
  end

  it 'retains inline reactions on grouped comments without an author heading' do
    create(:post_reaction, organisation: organisation, post: post_record, user: user)
    render_post(show_author: false)
    expect(page).to have_css('.post-head .post-reaction-chip')
  end

  it 'renders readable, keyboard-inspectable chips without write controls for readers' do
    role.update!(title: 'Ticket-Leser')
    role.permissions.destroy_all
    create(:project_read_permission, role: role, area: 'tickets')
    create(:post_reaction, organisation: organisation, post: post_record, user: create(:user))
    render_post
    expect(page).to have_css('span.post-reaction-chip[tabindex="0"]')
    expect(page).to have_no_css('.post-reaction-trigger')
    expect(page).to have_no_css('.post-reactions form')
  end
end
