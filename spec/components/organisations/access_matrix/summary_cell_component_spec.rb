# frozen_string_literal: true

require 'rails_helper'

# The org-matrix cell renders three visually distinct states and always encodes state by
# icon + label (never colour alone). Pins that "blocked" is its OWN state, NOT the neutral
# "never" cell, and that inherited access (admin/role) carries a lock.
RSpec.describe Organisations::AccessMatrix::SummaryCellComponent, type: :component do
  def cell(level:, source:, blocked: false, per_area: nil)
    per_area ||= ProjectPermission.access_areas.index_with { level }
    AccessCheck::OrgAccessMatrix::SummaryCell.new(
      level: level, source: source, blocked: blocked, per_area: per_area
    )
  end

  describe 'access state' do
    it 'renders a read_write grant as an emerald pill with icon + label, no lock when direct' do
      render_inline(described_class.new(cell: cell(level: 'read_write', source: :direct)))

      expect(page).to have_css('i.bi-pencil')
      expect(page).to have_text('Schreiben')
      expect(page).to have_no_css('i.bi-lock-fill')
      expect(page).to have_css('details.am-cell') # per-area popover only on access cells
    end

    it 'marks role-inherited access with a lock' do
      render_inline(described_class.new(cell: cell(level: 'read_only', source: :role)))

      expect(page).to have_css('i.bi-eye')
      expect(page).to have_css('i.bi-lock-fill')
    end

    it 'marks admin-inherited access with a lock' do
      render_inline(described_class.new(cell: cell(level: 'read_write', source: :admin)))

      expect(page).to have_css('i.bi-lock-fill')
    end
  end

  describe 'blocked state (distinct from never)' do
    it 'renders a red "Gesperrt" pill, not the neutral dash' do
      blocked = cell(level: 'no_access', source: :direct, blocked: true,
                     per_area: ProjectPermission.access_areas.index_with { 'no_access' })
      render_inline(described_class.new(cell: blocked))

      expect(page).to have_css('i.bi-x-circle')
      expect(page).to have_text('Gesperrt')
      expect(page).to have_no_css('i.bi-dash-lg') # NOT the "never" state
    end
  end

  describe 'never state' do
    it 'renders a neutral cream dash, never a red/error look' do
      render_inline(described_class.new(cell: cell(level: 'no_access', source: :none)))

      expect(page).to have_css('i.bi-dash-lg')
      expect(page).to have_text('Kein Zugriff')
      expect(page).to have_no_css('i.bi-x-circle') # NOT the blocked state
      expect(page).to have_no_css('.bg-red-100')
    end
  end

  describe 'per-area breakdown (tooltip)' do
    it 'lists every area with its effective level in a keyboard-reachable popover' do
      per_area = { tickets: 'read_write', notes: 'read_only', chats: 'no_access',
                   documents: 'no_access', members: 'no_access', documentation: 'no_access',
                   meetings: 'no_access' }
      render_inline(described_class.new(cell: AccessCheck::OrgAccessMatrix::SummaryCell.new(
        level: 'read_write', source: :direct, blocked: false, per_area: per_area
      )))

      # The popover is inside a collapsed <details>, so assert against the full DOM.
      # Derived from the area canon, not hard-coded: a new area must appear here
      # instead of silently going missing.
      expect(page).to have_css('.am-cell__pop-list li',
                               count: ProjectPermission.access_areas.size, visible: :all)
      expect(page).to have_css('.am-cell__pop-list li', text: 'Schreiben', visible: :all) # tickets
      expect(page).to have_css('.am-cell__pop-list li', text: 'Lesen', visible: :all)     # notes
    end
  end
end
