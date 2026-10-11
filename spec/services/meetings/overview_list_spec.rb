# frozen_string_literal: true

require 'rails_helper'

# The org-wide meetings list, extracted so the overview page and the save coming
# from its modal render the SAME list. The load-bearing property is that this
# object only ever NARROWS the scope it is handed: the Pundit scope stays with the
# caller, and a filter value must never be able to reach past it.
RSpec.describe Meetings::OverviewList do
  let(:organisation) { create(:organisation) }
  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Alpha') } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Beta') } }
  let(:creator) { create(:user) }

  def meeting(project:, title:, occurred_at: Time.current, participants: [])
    ActsAsTenant.with_tenant(organisation) do
      record = create(:meeting, project: project, organisation: organisation, creator: creator,
                                title: title, occurred_at: occurred_at)
      participants.each { |name| create(:meeting_participant, meeting: record, display_name: name) }
      record
    end
  end

  # The scope is built INSIDE the tenant block: Meeting.all outside one raises
  # NoTenantSet, and the default has to be lazy for the same reason.
  def results(scope: nil, **filters)
    ActsAsTenant.with_tenant(organisation) do
      described_class.new(scope: scope || Meeting.all, **filters).fetch_results.to_a
    end
  end

  describe '#fetch_results' do
    it 'never reaches past the scope it was given, not even with no filters' do
      inside = meeting(project: project_a, title: 'Alpha Kickoff')
      meeting(project: project_b, title: 'Beta Retro')

      scope = ActsAsTenant.with_tenant(organisation) { Meeting.where(project_id: project_a.id) }
      expect(results(scope: scope)).to eq([inside])
    end

    it 'cannot be widened by a project_id outside the given scope' do
      meeting(project: project_a, title: 'Alpha Kickoff')
      meeting(project: project_b, title: 'Beta Retro')

      scope = ActsAsTenant.with_tenant(organisation) { Meeting.where(project_id: project_a.id) }
      expect(results(scope: scope, project_id: project_b.id)).to be_empty
    end

    it 'narrows to one project when the project filter is set' do
      alpha = meeting(project: project_a, title: 'Alpha Kickoff')
      meeting(project: project_b, title: 'Beta Retro')

      expect(results(project_id: project_a.id)).to eq([alpha])
    end

    it 'filters by participant' do
      with_anna = meeting(project: project_a, title: 'Alpha Kickoff', participants: ['Anna Müller'])
      meeting(project: project_a, title: 'Beta Sync', participants: ['Bert Berg'])

      # The select's option VALUE is the normalized name, so that is what the page
      # sends. Feeding the display form here would pin a shape nothing produces.
      expect(results(participant: MeetingParticipant.normalize_name('Anna Müller'))).to eq([with_anna])
    end

    it 'treats blank filter values as no filter (an empty select must not empty the list)' do
      alpha = meeting(project: project_a, title: 'Alpha Kickoff')

      expect(results(search: '', participant: '', project_id: '')).to eq([alpha])
      expect(results(search: '   ', participant: '   ', project_id: '   ')).to eq([alpha])
    end

    it 'answers a project_id that is not a uuid with nothing instead of raising' do
      # The "a forged project_id cannot leak" claim rests on Rails casting an
      # unparseable uuid to NULL. project_id is NOT NULL, so nothing matches.
      meeting(project: project_a, title: 'Alpha Kickoff')

      expect { results(project_id: 'not-a-uuid') }.not_to raise_error
      expect(results(project_id: 'not-a-uuid')).to be_empty
    end

    it 'treats a non-scalar filter value as no filter at all' do
      # ?project_id[a]=1 arrives as ActionController::Parameters. That shape hurts
      # twice: `where` reads it as a condition on a table called project_id, and the
      # modal's route helper refuses to build an address from unpermitted parameters
      # (a 500 on a page anyone can call — the request-level probe for that lives in
      # meetings_overview_create_spec.rb). A value that is not a scalar is not a
      # filter, so the list stays unfiltered rather than raising or silently emptying.
      alpha = meeting(project: project_a, title: 'Alpha Kickoff')

      nested = ActionController::Parameters.new(a: '1')
      expect { results(project_id: nested) }.not_to raise_error
      expect(results(project_id: nested)).to eq([alpha])
      expect(results(search: nested, participant: ['x'], project_id: { 'a' => '1' })).to eq([alpha])
    end

    it 'loads only the list columns, never the ~1 MB text bodies' do
      # The whole reason this object narrows the SELECT. Dropping it has no symptom
      # a normal example would notice, only a slow page.
      meeting(project: project_a, title: 'Alpha Kickoff')

      row = results.first
      expect(row.title).to eq('Alpha Kickoff')
      expect { row.notes }.to raise_error(ActiveModel::MissingAttributeError)
      expect { row.transcript }.to raise_error(ActiveModel::MissingAttributeError)
    end

    it 'filters by search text' do
      kickoff = meeting(project: project_a, title: 'Alpha Kickoff')
      meeting(project: project_a, title: 'Beta Retro')

      expect(results(search: 'Kickoff')).to eq([kickoff])
    end

    it 'orders newest first' do
      older = meeting(project: project_a, title: 'Older', occurred_at: 3.days.ago)
      newer = meeting(project: project_a, title: 'Newer', occurred_at: 1.hour.ago)

      expect(results).to eq([newer, older])
    end

    it 'breaks an occurred_at tie by creation, so the newest entry is on top' do
      # occurred_at comes from a minute-resolution form field and defaults to "now",
      # so two meetings entered back to back tie. Without a second key the modal's
      # promise ("the new one is at the top") holds only by luck.
      same_moment = 2.hours.ago.change(sec: 0)
      first = meeting(project: project_a, title: 'Entered first', occurred_at: same_moment)
      second = meeting(project: project_a, title: 'Entered second', occurred_at: same_moment)

      expect(first.occurred_at).to eq(second.occurred_at)
      expect(results).to eq([second, first])
    end

    it 'combines filters instead of letting the last one win' do
      meeting(project: project_a, title: 'Alpha Kickoff', participants: ['Anna Müller'])
      meeting(project: project_b, title: 'Alpha Kickoff', participants: ['Anna Müller'])

      expect(results(search: 'Kickoff', participant: 'Anna Müller', project_id: project_a.id).size).to eq(1)
    end
  end

  describe '.from_params' do
    # The builder exists so the parameter NAMES live in one place: the overview
    # sends project_id, the save comes through the project-nested route where that
    # name is taken and the filter travels as overview_project_id.
    def from_params(params, **options)
      ActsAsTenant.with_tenant(organisation) do
        described_class.from_params(scope: Meeting.all, params: params.with_indifferent_access, **options)
                       .fetch_results.to_a
      end
    end

    it 'reads search, participant and project_id from the params' do
      alpha = meeting(project: project_a, title: 'Alpha Kickoff', participants: ['Anna Müller'])
      meeting(project: project_b, title: 'Beta Retro')

      expect(from_params({ search: 'Kickoff',
                           participant: MeetingParticipant.normalize_name('Anna Müller'),
                           project_id: project_a.id })).to eq([alpha])
    end

    it 'reads the project filter from overview_project_id for the nested route' do
      alpha = meeting(project: project_a, title: 'Alpha Kickoff')
      beta = meeting(project: project_b, title: 'Beta Retro')

      nested = { overview_project_id: project_a.id, project_id: project_b.id }
      # project_id is the nested route's own parameter and must be ignored here,
      # or a save would refresh the list filtered to the project it saved into.
      expect(from_params(nested, project_id_key: described_class::NESTED_PROJECT_ID_KEY)).to eq([alpha])
      expect(from_params(nested)).to eq([beta])
    end

    it 'defaults to the plain project_id key' do
      expect(described_class::DEFAULT_PROJECT_ID_KEY).to eq(:project_id)
      expect(described_class::NESTED_PROJECT_ID_KEY).to eq(:overview_project_id)
    end
  end

  describe '#filters_active?' do
    def active?(**filters)
      ActsAsTenant.with_tenant(organisation) do
        described_class.new(scope: Meeting.all, **filters).filters_active?
      end
    end

    it 'is false with no filters' do
      expect(active?).to be(false)
    end

    it 'is false for blank filter values (an empty select is not a filter)' do
      expect(active?(search: '', participant: '', project_id: '')).to be(false)
      expect(active?(search: '   ', participant: '   ', project_id: '   ')).to be(false)
    end

    it 'is false for a non-scalar value, so the empty state stays coherent' do
      # Otherwise the page would claim "your filter matched nothing" about a value
      # it never applied.
      expect(active?(project_id: ActionController::Parameters.new(a: '1'))).to be(false)
      expect(active?(search: { 'a' => '1' }, participant: ['x'])).to be(false)
    end

    it 'exposes exactly the filters it applied, ready for a URL' do
      list = ActsAsTenant.with_tenant(organisation) do
        described_class.new(scope: Meeting.all, search: 'Kickoff', participant: '  ',
                            project_id: ActionController::Parameters.new(a: '1'))
      end

      expect(list.active_filters).to eq(search: 'Kickoff')
    end

    it 'is true for each filter on its own' do
      expect(active?(search: 'x')).to be(true)
      expect(active?(participant: 'Anna')).to be(true)
      expect(active?(project_id: SecureRandom.uuid)).to be(true)
    end
  end
end
