# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Neo::Repository::IndexStatusComponent, type: :component do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def render_status(**attrs)
    index = create(:project_index, **attrs)
    render_inline(described_class.new(index: index))
    index
  end

  describe 'status badge' do
    described_class::STATUS_STYLES.each do |status, style|
      it "renders the #{status.inspect} label with its badge style" do
        render_status(status: status)
        expect(rendered_content).to include(I18n.t("views.organisations.indexing.status.#{status}"))
        expect(page).to have_css("span.#{style.split.first}")
      end
    end

    # Catches a status enum gaining a value the style map forgot: the view must
    # degrade to the neutral style + a humanized label, never blow up.
    it 'falls back to a humanized label + neutral style for an unknown status' do
      index = build(:project_index)
      index.status = 'archived'
      render_inline(described_class.new(index: index))
      expect(rendered_content).to include('Archived')
      expect(page).to have_css("span.#{described_class::DEFAULT_STYLE.split.first}")
    end
  end

  describe 'Layer-1 progress' do
    it 'shows the file counter while indexing once a total is known' do
      render_status(status: 'indexing', layer_1_files_total: 10, layer_1_files_done: 3)
      expect(rendered_content).to include('3 / 10')
    end

    # Boundary: total still 0 → the "0 / 0" counter is noise, hide it.
    it 'hides the counter until a total is known' do
      render_status(status: 'indexing', layer_1_files_total: 0, layer_1_files_done: 0)
      expect(rendered_content).not_to include('/ 0')
    end

    it 'also shows the counter while stale (a push re-index is in flight)' do
      render_status(status: 'stale', layer_1_files_total: 5, layer_1_files_done: 5)
      expect(rendered_content).to include('5 / 5')
    end

    it 'does not show the counter when ready (work is done)' do
      render_status(status: 'ready', layer_1_files_total: 8, layer_1_files_done: 8)
      expect(rendered_content).not_to include('8 / 8')
    end
  end

  describe 'ready state' do
    it 'shows the last-indexed time' do
      I18n.with_locale(:en) do
        render_status(status: 'ready', last_indexed_at: 2.hours.ago)
        expect(rendered_content).to match(/Last indexed .+ ago/)
      end
    end

    it 'shows "not indexed yet" when ready but no timestamp is set' do
      render_status(status: 'ready', last_indexed_at: nil)
      expect(rendered_content).to include(I18n.t('views.organisations.indexing.never_indexed'))
    end
  end

  describe 'failed state' do
    it 'shows the error message' do
      render_status(status: 'failed', error_message: 'OpenAI 500: upstream error')
      expect(rendered_content).to include(I18n.t('views.organisations.indexing.error_prefix'))
      expect(rendered_content).to include('OpenAI 500: upstream error')
    end

    # error_message is free text from git/provider stderr — the view uses <%= %>, so
    # it must be HTML-escaped, never raw. Pins the escaping (raw → stored XSS).
    it 'HTML-escapes the error message' do
      render_status(status: 'failed', error_message: '<script>alert(1)</script> upstream error')
      expect(rendered_content).not_to include('<script>alert(1)</script>')
      expect(rendered_content).to include('upstream error')
    end

    it 'renders no error block when there is no message' do
      render_status(status: 'failed', error_message: nil)
      expect(page).not_to have_css('.text-red-700')
    end
  end

  describe 'broadcast target contract' do
    # The root id MUST equal ProjectIndex#status_dom_id, otherwise a status
    # broadcast (which replaces that id) would render but land nowhere.
    it 'roots the markup at the index status_dom_id' do
      index = render_status(status: 'pending')
      expect(page).to have_css("##{index.status_dom_id}")
    end
  end
end
