# frozen_string_literal: true

require 'rails_helper'

# What: NeoTitleBoxComponent — the single shared page header for the whole app.
# Why:  The 2026-07 header unification decided: page titles render in normal case
#       (no uppercase tracking) with the context subtitle STACKED below in quiet
#       muted text (not inline mono). These assertions are load-bearing — a
#       regression back to `uppercase`/`font-mono` must break here, not slip
#       through silently. The wrapper assertions guard the (previously dead)
#       spacing params: margin/padding arguments must actually reach the DOM.
RSpec.describe NeoTitleBoxComponent, type: :component do
  it 'renders the title as a normal-case ink heading (no uppercase, no tracking)' do
    render_inline(described_class.new(title: 'Dokumentation'))

    expect(page).to have_css('h1.text-2xl.font-bold.text-heading', text: 'Dokumentation')
    expect(page).to have_no_css('h1.uppercase')
    expect(page).to have_no_css('h1.tracking-tight')
  end

  it 'stacks the subtitle below the title as quiet muted text (not inline mono)' do
    render_inline(described_class.new(title: 'Tickets', subtitle: 'Fakolith'))

    expect(page).to have_css('p.text-sm.text-muted', text: 'Fakolith')
    expect(page).to have_no_css('.font-mono', text: 'Fakolith')
    expect(page).to have_no_css('span.uppercase', text: 'Fakolith')
  end

  it 'omits the subtitle element entirely when no subtitle is given' do
    render_inline(described_class.new(title: 'Tickets'))

    expect(page).to have_no_css('p.text-muted')
  end

  it 'renders the badge next to the title line' do
    render_inline(described_class.new(title: 'Tickets', badge: 'Intelligenter Ordner'))

    expect(page).to have_css('span.text-xs', text: 'Intelligenter Ordner')
  end

  it 'renders right_content in the actions area' do
    render_inline(described_class.new(title: 'Tickets')) do |c|
      c.with_right_content { '<button id="action-btn">Neu</button>'.html_safe }
    end

    expect(page).to have_css('#action-btn', text: 'Neu')
  end

  # One order in every head (user, 2026-11-11): the page's tools first, the
  # main action outermost, as on the tickets and the time list. Until then a
  # title action stood before the tools on "Alle Meetings", Meetings, Wissen,
  # Personen and Glossar.
  describe 'the main action' do
    it 'stands after the tools, in its own box: 12 px from them, 3 px from the edge for its shadow' do
      render_inline(described_class.new(title: 'Meetings')) do |c|
        c.with_title_action { '<a id="main-action" href="/new">+</a>'.html_safe }
        c.with_right_content { '<button id="help">?</button>'.html_safe }
      end

      expect(page.all('#help, #main-action').map { |node| node[:id] }).to eq(%w[help main-action])
      box = page.find('#main-action').find(:xpath, '..')
      expect(box[:class]).to eq(described_class::TITLE_ACTION_CLASSES)
      expect(box[:class].split).to include('ms-1', 'me-[3px]')
    end

    it 'stands outermost in both groups of the three-column head' do
      render_inline(described_class.new(title: 'Meetings')) do |c|
        c.with_title_action { '<a class="main-action" href="/new">+</a>'.html_safe }
        c.with_right_content { '<button class="help">?</button>'.html_safe }
        c.with_center_content { '<span>Mitte</span>'.html_safe }
      end

      groups = page.all('div.gap-2', visible: :all).select { |group| group.has_css?('.main-action', visible: :all) }
      expect(groups.size).to eq(2)
      groups.each do |group|
        expect(group.all('.help, .main-action', visible: :all).map { |node| node[:class] }).to eq(%w[help main-action])
      end
    end

    it 'renders the tools alone without a main action, and the main action alone without tools' do
      render_inline(described_class.new(title: 'Meetings')) { |c| c.with_right_content { '<button id="help">?</button>'.html_safe } }
      expect(page).to have_css('#help')
      expect(page).to have_no_css(".#{described_class::TITLE_ACTION_CLASSES.split.first}")

      render_inline(described_class.new(title: 'Meetings')) { |c| c.with_title_action { '<a id="main-action" href="/new">+</a>'.html_safe } }
      expect(page).to have_css('#main-action')
    end
  end

  describe 'wrapper spacing' do
    it 'defaults to mb-6 with no top offset' do
      render_inline(described_class.new(title: 'Tickets'))

      expect(page).to have_css('div.mb-6')
      expect(page).to have_no_css('div.-mt-8')
      expect(page).to have_no_css('div.py-4')
    end

    it 'honors explicitly passed spacing params (previously silently ignored)' do
      render_inline(described_class.new(
                      title: 'Tickets',
                      margin_top: 'mt-4',
                      padding_y: 'py-2',
                      margin_bottom: 'mb-0'
                    ))

      expect(page).to have_css('div.mt-4.py-2.mb-0')
      expect(page).to have_no_css('div.mb-6')
    end
  end

  # On a phone the fixed head (layouts/_mobile_header) names the page, and
  # the head marks each line it would only repeat (MobileNavigationHelper#mobile_head_echo);
  # components/mobile_app.css hides the marked lines there. In a browser:
  # spec/system/phone_page_head_spec.rb.
  describe 'under the phone shell' do
    let(:echo) { ".#{described_class::PHONE_ECHO_CLASS}" }
    let(:organisation) { build_stubbed(:organisation, name: 'Nordlicht') }

    before do
      allow(vc_test_controller).to receive_messages(current_organisation: organisation, user_signed_in?: true,
                                                    current_project: nil)
    end

    it 'marks the title line and the organisation line, never the tools' do
      render_inline(described_class.new(title: 'Zeiten', badge: '3', variant: :organisation)) do |c|
        c.with_title_action { '<a id="main-action" href="/new">+</a>'.html_safe }
        c.with_right_content { '<button id="help">?</button>'.html_safe }
      end

      expect(page).to have_css("div#{echo} > h1", text: 'Zeiten')
      expect(page).to have_css("div#{echo} > span", text: '3')
      expect(page).to have_css("p#{echo}", text: 'Nordlicht')
      expect(page).to have_css('#help')
      expect(page).to have_css('#main-action')
      expect(page).to have_no_css("#{echo} #help, #{echo} #main-action")
    end

    it 'marks the whole head when nothing is left in it, so it takes no room' do
      render_inline(described_class.new(title: 'Projekte'))

      expect(page.find('h1', text: 'Projekte').ancestor('div.mb-6')[:class].split).to include(described_class::PHONE_ECHO_CLASS)
    end

    it 'keeps the head itself when a tool is left' do
      render_inline(described_class.new(title: 'Projekte')) { |c| c.with_right_content { '<button id="help">?</button>'.html_safe } }

      expect(page.find('h1', text: 'Projekte').ancestor('div.mb-6')[:class].split).not_to include(described_class::PHONE_ECHO_CLASS)
    end

    it 'keeps what the fixed head does not show: a later head of the page names its own title' do
      render_inline(described_class.new(title: 'Allgemein', variant: :organisation))
      render_inline(described_class.new(title: 'Vorschau', variant: :organisation))

      expect(page).to have_css('h1', text: 'Vorschau')
      expect(page).to have_no_css("#{echo} > h1")
      expect(page).to have_css("p#{echo}", text: 'Nordlicht')
    end
  end

  it 'marks nothing outside the phone shell' do
    render_inline(described_class.new(title: 'Zeiten', variant: :organisation))

    expect(page).to have_no_css(".#{described_class::PHONE_ECHO_CLASS}")
  end
end
