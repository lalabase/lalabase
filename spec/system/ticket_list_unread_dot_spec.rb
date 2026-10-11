# frozen_string_literal: true

require 'rails_helper'

# The ticket list's unread dot sits behind the number, inside a number column
# of fixed width that clips (layout.css, ".list table .number-column"). Until
# 29.09.2026 the column was 38px and a line break in the row partial put a
# space in front of the dot: every ticket from #100 on lost it entirely, while
# the server rendered it fine. Only a browser sees that, so this measures it.
RSpec.describe 'Ticket list unread dot', type: :system do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    Prosopite.pause
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    [9, 191, 9999].each do |number|
      ticket = create(:ticket, project: project, title: "Ticket #{number}", creator: user)
      ticket.update_column(:number, number)
      create(:notification, recipient: user, organisation: organisation, project: project, channel: 'in_app',
                            state: 'queued', event_type: Notifications::Constants::EVENT_TYPE_MENTION,
                            dedupe_fingerprint: "unread-dot-#{number}", notifiable: ticket)
    end
    sign_in user
  end

  after { Prosopite.resume }

  it 'keeps the dot inside the number cell up to a four-digit number' do
    visit organisation_project_tickets_path(organisation, project)
    expect(page).to have_css('[data-ticket-unread-for] [data-unread-marker="dot"]', count: 3)

    overflow = page.evaluate_script(<<~JS)
      [...document.querySelectorAll('[data-ticket-unread-for]')].map(wrapper => {
        const cell = wrapper.closest('td').getBoundingClientRect()
        const dot = wrapper.querySelector('[data-unread-marker]').getBoundingClientRect()
        return { number: wrapper.closest('td').innerText.trim(), px: Math.round(dot.right - cell.right) }
      })
    JS

    expect(overflow.map { |o| o['number'] }).to contain_exactly('#9', '#191', '#9999')
    expect(overflow).to all(include('px' => be <= 0))
  end
end
