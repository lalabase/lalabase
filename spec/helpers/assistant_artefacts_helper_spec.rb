# frozen_string_literal: true

require 'rails_helper'

# S3c T3: the way OUT of a report, shared by the source chip under an answer and
# the report panel itself. One owner, because a report whose two doors lead to
# two different lists is worse than one with a single door.
RSpec.describe AssistantArtefactsHelper do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  def query_of(path)
    Rack::Utils.parse_nested_query(URI.parse(path).query)
  end

  describe '#assistant_report_list_path' do
    # Kategorie 4: the neutralising params are the contract, not decoration. The
    # time list defaults to the CURRENT MONTH with billed rows hidden -- without
    # them the list beside the report would show a different set than the numbers
    # it was opened from, and nothing would say so.
    it 'neutralises the time list defaults, so the list shows what the report counted' do
      query = query_of(helper.assistant_report_list_path(organisation, project, {}))

      expect(query['status_filters']).to match_array(TimeSession::BILLING_STATUS_FILTERS)
      expect(query['date_range']).to eq('all')
    end

    it 'carries every filter the report was addressed by' do
      filters = { start_date: '2026-05-01', end_date: '2026-05-31',
                  creator_id: SecureRandom.uuid, ticket_id: SecureRandom.uuid }

      query = query_of(helper.assistant_report_list_path(organisation, project, filters))

      expect(query).to include(filters.transform_keys(&:to_s).transform_values(&:to_s))
    end

    it 'takes string keys as well, because a citation comes out of JSONB' do
      query = query_of(helper.assistant_report_list_path(organisation, project,
                                                         { 'start_date' => '2026-05-01' }))

      expect(query['start_date']).to eq('2026-05-01')
    end

    # Kategorie 2, the negative half: anything outside the four keys is dropped.
    # Otherwise a crafted citation could hand the list a filter of its own.
    it 'drops keys outside REPORT_FILTER_KEYS' do
      query = query_of(helper.assistant_report_list_path(
                         organisation, project,
                         { start_date: '2026-05-01', billing_status: 'billed', search: 'x' }
                       ))

      expect(query.keys).not_to include('billing_status', 'search')
    end

    it 'drops blank values instead of sending empty filters' do
      query = query_of(helper.assistant_report_list_path(organisation, project,
                                                         { start_date: nil, end_date: '2026-05-31' }))

      expect(query).not_to have_key('start_date')
      expect(query['end_date']).to eq('2026-05-31')
    end

    # A JSONB column can hold anything. There is a component spec for the same
    # case; this pins the shared owner directly, because that is where the guard
    # actually sits.
    it 'survives filters that are not a hash at all' do
      expect { helper.assistant_report_list_path(organisation, project, 'kaputt') }.not_to raise_error
      expect { helper.assistant_report_list_path(organisation, project, nil) }.not_to raise_error
    end
  end

  describe '#assistant_report_filter_summary' do
    # The header is rendered before a single row is. Resolving an id to a name
    # there would answer the very question the rows below refuse to answer.
    it 'names no person for a foreign creator id' do
      # Distinctive on purpose: the German wording itself contains the word
      # "Person", so a name like that would collide with the label and the test
      # would fail for the wrong reason.
      stranger = create(:user, first_name: 'Zwetschge', last_name: 'Ohrwurm')
      panel = instance_double(Assistant::Panels::TimeReport, filters: { creator_id: stranger.id })
      allow(helper).to receive(:current_user).and_return(create(:user))

      summary = helper.assistant_report_filter_summary(panel)

      expect(summary).not_to include('Zwetschge', 'Ohrwurm', stranger.id)
      expect(summary).to include(I18n.t('views.organisations.assistant_artefacts.report.filters.one_person'))
    end

    it 'says "your bookings" for the reader own id, which tells them nothing new' do
      reader = create(:user)
      panel = instance_double(Assistant::Panels::TimeReport, filters: { creator_id: reader.id })
      allow(helper).to receive(:current_user).and_return(reader)

      expect(helper.assistant_report_filter_summary(panel))
        .to include(I18n.t('views.organisations.assistant_artefacts.report.filters.own_bookings'))
    end

    # Kategorie 3: all four shapes of a period, including the two half-open ones,
    # which is where a missing branch would silently print "all time".
    {
      {} => 'all_time',
      { start_date: '2026-05-01', end_date: '2026-05-31' } => 'period',
      { start_date: '2026-05-01' } => 'period_from',
      { end_date: '2026-05-31' } => 'period_until'
    }.each do |filters, key|
      it "renders the #{key} wording for #{filters.inspect}" do
        panel = instance_double(Assistant::Panels::TimeReport, filters: filters)
        allow(helper).to receive(:current_user).and_return(create(:user))

        summary = helper.assistant_report_filter_summary(panel)
        other_keys = %w[all_time period period_from period_until] - [key]

        expect(summary).to be_present
        # The chosen wording must be the one that fits, not merely A wording: the
        # half-open cases fall onto the wrong branch without an elsif.
        expect(summary).not_to include(*other_keys.map do |k|
          I18n.t("views.organisations.assistant_artefacts.report.filters.#{k}",
                 from: '1.1.1000', to: '2.2.2000')
        end)
      end
    end

    # ⚠️ `format: :short` carries no year, and a billing period without one is
    # ambiguous the moment January arrives.
    it 'writes the year into both ends of a period' do
      panel = instance_double(Assistant::Panels::TimeReport,
                              filters: { start_date: '2026-05-01', end_date: '2026-05-31' })
      allow(helper).to receive(:current_user).and_return(create(:user))

      expect(helper.assistant_report_filter_summary(panel)).to include('2026').twice
    end
  end
end
