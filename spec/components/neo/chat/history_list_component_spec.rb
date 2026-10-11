# frozen_string_literal: true

require 'rails_helper'

# Neo::Chat::HistoryListComponent — the assistant's earlier conversations
# (S3c T1, plan §7.6).
#
# The request spec follows the endpoint; this one pins the two pieces of logic
# that live in the component and would otherwise only be reachable through it:
# where the back arrow points when nothing is open, and that the date carries a
# YEAR. The second one is not decoration — `time.formats.short` in this app is
# "%d %b %H:%M" and `date.formats.short` is "%d.%m.", so a list whose whole job
# is finding something from a while ago would print last August and this August
# identically.
RSpec.describe Neo::Chat::HistoryListComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def thread(content, created_at: Time.current)
    chat = create(:chat, :org_thread, organisation: organisation, user: user, created_at: created_at)
    chat.chatposts.first.update!(user: user, content: content)
    chat
  end

  def render_list(threads:, current_chat: nil)
    render_inline(
      described_class.new(threads: threads, current_chat: current_chat, current_organisation: organisation)
    )
  end

  describe 'the rows' do
    it 'names each thread by its first message' do
      chat = thread('Wie viele Stunden')

      render_list(threads: [chat])

      expect(page).to have_text(chat.first_message)
    end

    it 'prints a date that carries the YEAR' do
      chat = thread('Frage', created_at: Time.zone.local(2025, 8, 25, 10, 0))

      render_list(threads: [chat])

      expect(page).to have_text('25.08.2025')
    end

    it 'marks the open thread and leaves the others unmarked' do
      open_chat = thread('Offene Frage')
      other     = thread('Andere Frage')

      render_list(threads: [open_chat, other], current_chat: open_chat)

      expect(page).to have_css("[data-chat-id='#{open_chat.id}'][data-assistant-history-current='true']")
      expect(page).to have_css("[data-chat-id='#{other.id}'][data-assistant-history-current='false']")
    end

    it 'marks the open row for assistive technology too, not only visually' do
      open_chat = thread('Offene Frage')

      render_list(threads: [open_chat], current_chat: open_chat)

      expect(page).to have_css("[data-chat-id='#{open_chat.id}'][aria-current='true']")
    end
  end

  describe 'the way back' do
    # With a thread open, back means back to THAT one — not to the panel's
    # default, which is the newest and would silently switch the conversation
    # under somebody who only wanted to glance at the list.
    it 'points at the open thread when there is one' do
      open_chat = thread('Offene Frage')
      thread('Neuere Frage')

      render_list(threads: [open_chat], current_chat: open_chat)

      back = page.find("a[aria-label='#{I18n.t('views.organisations.assistant_panels.history.back')}']")
      expect(back['href']).to eq(
        Rails.application.routes.url_helpers.organisation_assistant_panel_path(
          organisation_id: organisation.id, chat_id: open_chat.id
        )
      )
    end

    # Without one (the panel was showing the empty composer, or ?current= named
    # something this viewer does not own) it falls back to the panel's own
    # default address rather than rendering a dead arrow.
    it 'falls back to the panel default when nothing is open' do
      render_list(threads: [thread('Frage')])

      back = page.find("a[aria-label='#{I18n.t('views.organisations.assistant_panels.history.back')}']")
      expect(back['href']).to eq(
        Rails.application.routes.url_helpers.organisation_assistant_panel_path(organisation_id: organisation.id)
      )
    end

    it 'never leaves the panel frame' do
      render_list(threads: [thread('Frage')])

      targets = page.all('a').map { |link| link['data-turbo-frame'] }

      expect(targets).to all(eq('assistant_panel_body'))
    end
  end

  # The header button lives in the permanent shell and cannot see what the frame
  # is holding. This marker is the one thing that tells it the list is ALREADY
  # open; without it a second press rebuilds the address from a chat frame that
  # is no longer in the document, goes out without ?current=, and the back arrow
  # above swings to the newest thread instead of the one the list was called
  # from. The JS half is a system spec; this pins the half a server can hold.
  describe 'the marker the panel controller reads' do
    it 'announces that the list is on screen' do
      render_list(threads: [thread('Frage')])

      expect(page).to have_css('[data-assistant-history]')
    end

    it 'announces it in the empty state too, where a second press is likeliest' do
      render_list(threads: [])

      expect(page).to have_css('[data-assistant-history]')
    end
  end

  # S3c T2: the same list on two surfaces. The overlay REPLACED the transcript, so
  # it owes the user a way back; the lane stands permanently beside it and owes
  # nothing.
  # Positive iteration over the CONSTANT. Both surfaces exist because they differ,
  # so a variant dropped from the whitelist would start raising for a caller that
  # is perfectly correct, and a variant added to it would arrive untested.
  describe 'every variant in the whitelist' do
    described_class::VARIANTS.each do |variant|
      it "renders the #{variant} variant with rows" do
        chat = thread('Frage')

        render_inline(
          described_class.new(threads: [chat], current_organisation: organisation, variant: variant)
        )

        expect(page).to have_css("a[data-chat-id='#{chat.id}']")
        expect(page).to have_text(I18n.t('views.organisations.assistant_panels.history.title'))
      end

      it "renders the #{variant} variant with nothing to show" do
        render_inline(
          described_class.new(threads: [], current_organisation: organisation, variant: variant)
        )

        expect(page).to have_text(I18n.t('views.organisations.assistant_panels.history.empty'))
      end
    end
  end

  describe 'the lane variant' do
    def render_lane(threads:, current_chat: nil)
      render_inline(
        described_class.new(threads: threads, current_chat: current_chat,
                            current_organisation: organisation, variant: :lane)
      )
    end

    it 'has no way back, because it did not take anything away' do
      render_lane(threads: [thread('Frage')])

      expect(page).to have_no_css("a[aria-label='#{I18n.t('views.organisations.assistant_panels.history.back')}']")
    end

    it 'still points its rows at the chat frame, so the lane stays put' do
      chat = thread('Frage')

      render_lane(threads: [chat])

      expect(page).to have_css("a[data-chat-id='#{chat.id}'][data-turbo-frame='assistant_panel_body']")
    end

    it 'still marks the open thread' do
      chat = thread('Frage')

      render_lane(threads: [chat], current_chat: chat)

      expect(page).to have_css("[data-chat-id='#{chat.id}'][data-assistant-history-current='true']")
    end

    it 'still says so when there is nothing to show' do
      render_lane(threads: [])

      expect(page).to have_text(I18n.t('views.organisations.assistant_panels.history.empty'))
    end

    # A typo in a variant must not render a surface that quietly behaves like the
    # other one — the difference between them is a missing way back, which is
    # exactly the kind of thing nobody notices in a screenshot.
    it 'refuses an unknown variant instead of guessing' do
      expect do
        described_class.new(threads: [], current_organisation: organisation, variant: :sidebar)
      end.to raise_error(ArgumentError, /sidebar/)
    end
  end

  describe 'with nothing to show' do
    it 'says so instead of rendering an empty list' do
      render_list(threads: [])

      expect(page).to have_text(I18n.t('views.organisations.assistant_panels.history.empty'))
      expect(page).to have_no_css('ul')
    end

    it 'still offers the way back' do
      render_list(threads: [])

      expect(page).to have_css("a[aria-label='#{I18n.t('views.organisations.assistant_panels.history.back')}']")
    end
  end
end
