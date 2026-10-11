# frozen_string_literal: true

require 'rails_helper'

# What: The one declaration of the time list's filters, and the rules that make
#       it the owner rather than a sixth copy: every filter-service attribute
#       belongs to exactly one filter, a removal clears what its filter owns,
#       and the badge and the reset read each filter's own answer.
# Why:  Each filter used to be written out by hand in five places (removal map,
#       empty-state units, badge count, reset target, hidden fields). The badge
#       count had drifted twice. Three new filters were planned on 29.09.2026.
RSpec.describe TimeSessions::ListFilters do
  let(:all_states) { TimeSession::BILLING_STATUS_FILTERS }

  # The untouched page: this month, billed hidden, nothing chosen.
  let(:default_state) do
    { date_range: TimeSessions::ListPeriod::LIST_DEFAULT, status_filters: TimeSession::DEFAULT_STATUS_FILTERS }
  end

  # Where the reset leads: all time, all three states, nothing chosen.
  let(:neutral_state) { { date_range: 'all', status_filters: all_states } }

  describe 'the filter service attributes' do
    # `project` is the project page's own scope, `smart_folder` the base query
    # and `readable_tickets` the reader's ticket rights: none of them is a
    # filter the reader sets or removes on the list.
    let(:not_list_filters) { %w[project smart_folder readable_tickets] }

    it 'belong to exactly one filter each, so a new attribute cannot be missed' do
      owned = described_class::ALL.flat_map(&:attributes).map(&:to_s)

      expect(owned).to match_array(TimeSessionFilterService.attribute_names - not_list_filters)
      expect(owned).to eq(owned.uniq)
    end
  end

  describe 'a removal' do
    # EmptyReason probes a filter by leaving its attributes out, the page then
    # removes it by following its removal. If the two cover different
    # parameters, the page promises rows the link does not bring back.
    it 'touches every parameter its filter owns' do
      described_class::ALL.each do |filter|
        expect(filter.removal.keys).to include(*filter.attributes.map(&:to_s)), filter.key.to_s
      end
    end

    it 'takes the subject along with the project' do
      expect(described_class.removal(:project)).to include('ticket_id' => nil, 'meeting_id' => nil)
    end

    # A status value is a word of one project (step 3b); a phase is not.
    it 'takes the ticket status value along with the project, not the phase' do
      expect(described_class.removal(:project)).to include('ticket_status' => nil)
      expect(described_class.removal(:project)).not_to have_key('ticket_phase')
    end

    it 'opens the period and switches every state on instead of clearing them' do
      expect(described_class.removal(:period)).to include('date_range' => 'all')
      expect(described_class.removal(:status)).to include('status_filters' => all_states)
    end
  end

  describe 'the carried parameters' do
    it 'are parameters a filter owns' do
      owned = described_class::ALL.flat_map(&:attributes).map(&:to_s)

      expect(owned).to include(*described_class.carried_params)
    end

    # A field of the form must not travel a second time as a hidden copy.
    it 'leave out what the form has a field for' do
      expect(described_class.carried_params).not_to include('search', 'start_date', 'end_date')
    end
  end

  describe '.plain_attributes_from' do
    it 'reads the plain filters off the request and nothing else' do
      params = ActionController::Parameters.new(creator_id: 'c', ticket_id: 't', search: 's',
                                                date_range: 'year', status_filters: ['billed'])

      expect(described_class.plain_attributes_from(params))
        .to eq(project_id_filter: nil, ticket_id: 't', meeting_id: nil,
               time_session_group_id: nil, creator_id: 'c', tag_id: nil, ticket_phase: nil, ticket_status: nil,
               search: 's')
    end
  end

  # The page compares ids in Ruby, the database compares them as uuids. Both
  # have to read an id the same way, or the page names one person over a list
  # filtered to another, or to nobody (review, 29.09.2026).
  describe '.normalize_id' do
    let(:uuid) { 'ab12cd34-0000-4000-8000-00000000abcd' }

    it 'spells every form the database accepts the way the database stores it' do
      [uuid.upcase, uuid.delete('-'), "{#{uuid}}"].each do |spelling|
        expect(described_class.normalize_id(spelling)).to eq(uuid), spelling
      end
    end

    # Rejected by the database too: the query becomes "= NULL" and the list is
    # empty. Passed on unchanged it stays a filter that is set and names nobody.
    it 'leaves what the database rejects as it is' do
      [" #{uuid} ", 'junk'].each do |spelling|
        expect(described_class.normalize_id(spelling)).to eq(spelling)
      end
    end

    it 'agrees with the query for every spelling' do
      type = TimeSession.type_for_attribute(:creator_id)

      [uuid, uuid.upcase, uuid.delete('-'), " #{uuid} ", 'junk'].each do |spelling|
        cast = type.cast(spelling)
        expect(described_class.normalize_id(spelling)).to eq(cast || spelling), spelling
      end
    end

    it 'passes anything that is not a String through' do
      expect(described_class.normalize_id(['x'])).to eq(['x'])
      expect(described_class.normalize_id(nil)).to be_nil
    end
  end

  describe 'Filter#deviates? and #neutral?' do
    it 'finds nothing deviating on the untouched page' do
      expect(described_class::ALL.select { |filter| filter.deviates?(default_state) }).to be_empty
    end

    it 'finds everything neutral on the list the reset leads to' do
      expect(described_class::ALL.reject { |filter| filter.neutral?(neutral_state) }).to be_empty
    end

    it 'counts the neutral list as deviating twice: all time and all three states' do
      expect(described_class::ALL.select { |filter| filter.deviates?(neutral_state) }.map(&:key))
        .to contain_exactly(:period, :status)
    end

    # A plain filter is set by its RECORD where it names one: an id the reader
    # may not read resolves to nil and is no filter the page can show or count.
    it 'reads a plain filter off its state keys' do
      subject_filter = described_class::BY_KEY.fetch(:subject)

      expect(subject_filter.deviates?(default_state.merge(meeting: Object.new))).to be(true)
      expect(subject_filter.deviates?(default_state.merge(ticket: nil))).to be(false)
      expect(subject_filter.neutral?(neutral_state.merge(ticket: Object.new))).to be(false)
    end

    it 'treats a custom period as off the default and off the reset target' do
      period = described_class::BY_KEY.fetch(:period)
      custom = { date_range: TimeSessions::ListPeriod::CUSTOM }

      expect(period.deviates?(custom)).to be(true)
      expect(period.neutral?(custom)).to be(false)
    end
  end

  # A key without a name in one locale is a "translation missing" nobody sees
  # (raise_on_missing_translations is off in test).
  describe 'the keys' do
    it 'have a name in both locales' do
      %i[de en].each do |locale|
        names = I18n.t('views.organisations.time_sessions.empty_reason.names', locale: locale)
        expect(names.keys).to match_array(described_class::KEYS), "#{locale}: #{names.keys.inspect}"
      end
    end
  end
end
