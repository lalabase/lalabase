# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationHelper, '#changelog_has_unread?' do
  let(:user) { create(:user) }

  def make_entry(date:, title: 'Test')
    Changelog::EntryLoader::Entry.new(
      slug: "#{date}_test",
      title: title,
      date: date,
      images: [],
      body: 'test',
      body_html: '<p>test</p>'
    )
  end

  before do
    allow(Changelog::EntryLoader).to receive(:call).and_return(entries)
  end

  context 'wenn keine Changelog-Einträge vorhanden sind' do
    let(:entries) { [] }

    it 'zeigt keinen Punkt' do
      expect(helper.changelog_has_unread?(user)).to be false
    end
  end

  context 'wenn User noch nie auf der Seite war' do
    let(:entries) { [make_entry(date: Date.new(2026, 3, 2))] }

    it 'zeigt den Punkt' do
      expect(helper.changelog_has_unread?(user)).to be true
    end
  end

  context 'wenn User Neuigkeiten zum ersten Mal besucht' do
    let(:entries) { [make_entry(date: Date.new(2026, 3, 2))] }

    it 'Punkt ist vorher sichtbar und verschwindet nach Seitenbesuch' do
      expect(helper.changelog_has_unread?(user)).to be true

      user.update_column(:changelog_last_read_at, Time.current)

      expect(helper.changelog_has_unread?(user.reload)).to be false
    end
  end

  context 'wenn User erneut besucht ohne neuen Eintrag' do
    let(:entries) { [make_entry(date: Date.new(2026, 3, 2))] }

    it 'zeigt keinen Punkt' do
      user.update_column(:changelog_last_read_at, Time.zone.parse('2026-03-02 14:30'))

      expect(helper.changelog_has_unread?(user.reload)).to be false
    end
  end

  context 'wenn neuer Changelog-Eintrag seit letztem Besuch deployt wird' do
    let(:entries) do
      [
        make_entry(date: Date.new(2026, 3, 5), title: 'Neues Feature'),
        make_entry(date: Date.new(2026, 3, 2), title: 'Alter Eintrag')
      ]
    end

    it 'Punkt erscheint bei Usern, die seit dem Eintragsdatum nicht auf der Seite waren' do
      user.update_column(:changelog_last_read_at, Time.zone.parse('2026-03-02 14:30'))

      expect(helper.changelog_has_unread?(user.reload)).to be true
    end
  end
end
