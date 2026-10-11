# frozen_string_literal: true

require 'rails_helper'

# What: Tickets::BulkSelection, the one resolver of a bulk selection into ids
#   (doc/ticket_bulk_edit_plan.md, slice 2).
# Type: service spec.
# Why: an id outside the reader's scope must refuse the whole selection, "all"
#   must follow the list's own relation and refuse a stale count, and the cap
#   must hold at n, fail at n+1, for both modes. A grouped relation yields
#   duplicate ids on pluck; the uniq is load bearing.
RSpec.describe Tickets::BulkSelection do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }
  let(:scope) { project.tickets }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def make_ticket(project, title = 'Ticket')
    create(:ticket, title: title, project: project, organisation: organisation, creator: user)
  end

  describe 'mode ids' do
    let!(:mine) { [make_ticket(project, 'a'), make_ticket(project, 'b')] }
    let!(:foreign) { make_ticket(other_project, 'c') }

    it 'resolves the ticked ids that are in the scope' do
      resolution = described_class.call(scope: scope, selection: { mode: 'ids', ids: mine.map(&:id) })

      expect(resolution).to be_ok
      expect(resolution.ids).to match_array(mine.map(&:id))
      expect(resolution.count).to eq(2)
    end

    it 'refuses the whole selection when one id is outside the scope' do
      resolution = described_class.call(scope: scope, selection: { mode: 'ids', ids: [mine.first.id, foreign.id] })

      expect(resolution).not_to be_ok
      expect(resolution.error).to eq(:outside_scope)
      expect(resolution.ids).to be_empty
    end

    context 'when the scope returns duplicate rows' do
      let(:scope) { project.tickets.includes(:taggings) }

      before do
        %w[first second].each do |name|
          tag = create(:tag, name: name, organisation: organisation)
          create(:tagging, tag: tag, taggable: mine.first)
        end
      end

      it 'resolves valid selections with each ticket counted once' do
        resolution = described_class.call(scope: scope, selection: { mode: 'ids', ids: mine.map(&:id) })

        expect(resolution).to be_ok
        expect(resolution.ids).to match_array(mine.map(&:id))
        expect(resolution.count).to eq(2)
      end

      it 'refuses an outside-scope id even when duplicates make the row count match' do
        resolution = described_class.call(scope: scope, selection: { mode: 'ids', ids: [mine.first.id, foreign.id] })

        expect(resolution.error).to eq(:outside_scope)
        expect(resolution.ids).to be_empty
      end
    end

    it 'refuses an empty selection, an unknown id and an unknown mode' do
      expect(described_class.call(scope: scope, selection: { mode: 'ids', ids: [] }).error).to eq(:empty)
      expect(described_class.call(scope: scope, selection: { mode: 'ids', ids: [SecureRandom.uuid] }).error).to eq(:outside_scope)
      expect(described_class.call(scope: scope, selection: { mode: 'later', ids: mine.map(&:id) }).error).to eq(:unknown_mode)
      expect(described_class.call(scope: scope, selection: nil).error).to eq(:unknown_mode)
    end

    it 'reads ActionController::Parameters as the request sends them' do
      params = ActionController::Parameters.new(mode: 'ids', ids: mine.map(&:id))

      expect(described_class.call(scope: scope, selection: params)).to be_ok
    end

    it 'holds the cap at n and refuses n + 1' do
      stub_const('Tickets::BulkSelection::MAX_TICKETS', 2)
      third = make_ticket(project, 'd')

      expect(described_class.call(scope: scope, selection: { mode: 'ids', ids: mine.map(&:id) })).to be_ok
      expect(described_class.call(scope: scope, selection: { mode: 'ids', ids: (mine + [third]).map(&:id) }).error).to eq(:too_many)
    end
  end

  describe 'mode all' do
    let!(:hits) { [make_ticket(project, 'Bug one'), make_ticket(project, 'Bug two')] }
    let!(:miss) { make_ticket(project, 'Plain') }
    let(:relation) { -> { project.tickets.where('title ILIKE ?', 'Bug%') } }

    it 'resolves every hit of the list relation' do
      resolution = described_class.call(scope: scope, selection: { mode: 'all', expected_count: 2 }, filtered_relation: relation)

      expect(resolution).to be_ok
      expect(resolution.ids).to match_array(hits.map(&:id))
    end

    it 'refuses when the count the reader saw is not the count the list has now' do
      resolution = described_class.call(scope: scope, selection: { mode: 'all', expected_count: 3 }, filtered_relation: relation)

      expect(resolution.error).to eq(:list_changed)
      expect(resolution.ids).to be_empty
    end

    it 'does not need an expected count' do
      expect(described_class.call(scope: scope, selection: { mode: 'all' }, filtered_relation: relation)).to be_ok
    end

    it 'refuses without a list, and an empty list' do
      expect(described_class.call(scope: scope, selection: { mode: 'all' }).error).to eq(:no_list)
      none = -> { project.tickets.where(title: 'nothing') }
      expect(described_class.call(scope: scope, selection: { mode: 'all' }, filtered_relation: none).error).to eq(:empty)
    end

    it 'holds the cap at n and refuses n + 1' do
      stub_const('Tickets::BulkSelection::MAX_TICKETS', 2)
      all = -> { project.tickets }

      expect(described_class.call(scope: scope, selection: { mode: 'all' }, filtered_relation: relation)).to be_ok
      expect(described_class.call(scope: scope, selection: { mode: 'all' }, filtered_relation: all).error).to eq(:too_many)
    end

    it 'counts a ticket once when the relation joins it twice' do
      tag_a = create(:tag, name: 'a', organisation: organisation)
      tag_b = create(:tag, name: 'b', organisation: organisation)
      create(:tagging, tag: tag_a, taggable: hits.first)
      create(:tagging, tag: tag_b, taggable: hits.first)
      joined = -> { project.tickets.joins(:taggings).order('taggings.created_at') }

      resolution = described_class.call(scope: scope, selection: { mode: 'all', expected_count: 1 }, filtered_relation: joined)

      expect(resolution).to be_ok
      expect(resolution.ids).to eq([hits.first.id])
    end
  end
end
