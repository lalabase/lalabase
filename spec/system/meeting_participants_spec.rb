# frozen_string_literal: true

require 'rails_helper'

# End-to-end JS wiring for the participant SlimSelect field — the layer the model /
# actor / request / node:test specs can't reach: the Stimulus controller connects,
# SlimSelect initializes on the native <select multiple>, the importmap bare
# specifiers (slim-select + meetings/participant_parser + name_normalizer) actually
# resolve in a real browser, and the Option-C mirror wires the current selection
# into the indexed hidden inputs so a save persists user_id vs. external correctly.
#
# Reworked from the Slice 1b chip combobox: names are now selected directly (no
# confirm step — plan decision 1), members link via a "user:<uuid>" option value,
# external names are added via SlimSelect `addable`, and the offline transcript
# parser feeds the same field on paste. The "removed everyone → cleared" sentinel
# path is proven at the (reliable, non-browser) actor level instead.
#
# SlimSelect 2.9.2 note: the dropdown content (.ss-content > .ss-list > .ss-option,
# the search input, the .ss-addable button) is appended to document.body, so those
# are matched globally; the tokens (.ss-value / .ss-value-text) live in .ss-main.
RSpec.describe 'Meeting participant field (SlimSelect)', type: :system do
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  # A second project member so the member link (user_id) is unambiguous vs. the
  # signed-in creator.
  let(:member) do
    u = create(:user, first_name: 'Mara', last_name: 'Meier')
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation,
                          role: create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation), active: true)
      create(:project_permission, user: u, project: project, meetings_access: 'read_write')
    end
    u
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  def open_participant_select
    find('#meeting-participants-select', visible: :all).sibling('.ss-main').click
  end

  it 'links a member, adds an external name, adopts parsed names, and saves each correctly' do
    member_name = member.display_name

    visit organisation_project_meetings_path(organisation, project)
    click_on I18n.t('views.organisations.meetings.index.new_meeting')

    expect(page).to have_field('Titel')
    fill_in 'Titel', with: 'Kickoff Call'

    # 1) Pick a project member from the dropdown → linked (user_id) token.
    #    (have_selector waits — SlimSelect debounces its afterChange.)
    open_participant_select
    find('.ss-option', text: member_name).click
    expect(page).to have_selector('.ss-main .ss-value-text', text: member_name)

    # 2) Add an external free-text name via `addable` (dropdown stays open —
    #    closeOnSelect is false — so the search box is still present). Enter on the
    #    search input triggers the addable (SlimSelect 2.9.2 keydown handler).
    search = find('.ss-search input')
    search.set('Extern Otto')
    search.send_keys(:enter)
    expect(page).to have_selector('.ss-main .ss-value-text', text: 'Extern Otto')

    # 3) Paste a transcript → the offline parser selects the speaker names directly
    #    (no confirm step). Proves the bare-specifier imports resolve in the browser.
    page.execute_script(<<~JS)
      const ta = document.querySelector('[data-meeting-participants-target="transcript"]');
      ta.value = '**Karl Krause:** Guten Morgen.\\n**Bert Bauer:** Moin zusammen.';
      ta.dispatchEvent(new Event('paste'));
    JS
    expect(page).to have_selector('.ss-main .ss-value-text', text: 'Karl Krause')
    expect(page).to have_selector('.ss-main .ss-value-text', text: 'Bert Bauer')

    click_on I18n.t('views.organisations.meetings.form.save')
    expect(page).to have_css('h2', text: 'Kickoff Call')

    meeting = ActsAsTenant.with_tenant(organisation) { Meeting.find_by(title: 'Kickoff Call') }
    participants = meeting.meeting_participants.index_by(&:display_name)

    # Member is linked; the free-text and parsed names are external (no user_id).
    expect(participants.keys).to contain_exactly(member_name, 'Extern Otto', 'Karl Krause', 'Bert Bauer')
    expect(participants[member_name].user_id).to eq(member.id)
    expect(participants['Extern Otto'].user_id).to be_nil
    expect(participants['Karl Krause'].user_id).to be_nil
  end
end
