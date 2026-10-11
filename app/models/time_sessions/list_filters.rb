# frozen_string_literal: true

module TimeSessions
  # Every filter of the time list, declared ONCE: which filter-service
  # attributes it owns, what switching it off changes in the address, which
  # entries of the filter state say it is set, and which parameters the filter
  # form has to carry on a submit.
  #
  # Entry point: ALL / BY_KEY, then the questions a Filter answers.
  #
  # Why an owner: before it, each filter was written out by hand in five places
  # that all had to agree -- the removal map in TimeSessionsHelper, the
  # removable units of TimeSessions::EmptyReason, the mobile badge count, the
  # reset target and the hidden fields of the filter form -- plus the hash the
  # controller hands to TimeSessionFilterService. The badge count had already
  # drifted twice (it knew neither meeting_id nor creator_id). Three more
  # filters were planned (person, tag, ticket status, 29.09.2026), and the
  # plan grew by slices repeating the same operation in every place. A new
  # filter is one entry here now; spec/models/time_sessions/list_filters_spec.rb
  # fails when the filter service knows an attribute this list does not.
  #
  # What stays per filter outside this file: its pill in _filter_line, the
  # record it names (TimeSessionsController#load_filter_selection) and the
  # words (TimeSessionsHelper#time_filter_removal_value, the locale names).
  # Those are display, and each is a different question per filter.
  module ListFilters
    # key        -- the word the page speaks in: the pill, the empty state,
    #               views.organisations.time_sessions.empty_reason.names.<key>
    # kind       -- :plain is either set or not. :period and :status are never
    #               unset: each always has a value, a default the untouched page
    #               shows and a neutral value the reset leads to.
    # attributes -- the TimeSessionFilterService attributes this unit owns.
    #               Every attribute there defaults to nil, so leaving these out
    #               IS switching the filter off (EmptyReason's probe).
    # removal    -- the address change that switches it off, in the Hash shape
    #               time_list_filter_url takes (nil clears a key).
    # state_keys -- the filter-state entries (build_filter_state) that say a
    #               :plain filter is set. A record, not the raw id, where the
    #               filter names one: an id the reader may not read is no
    #               filter the page can show, count or offer to undo.
    # carried    -- parameters a LINK sets, which the filter form therefore has
    #               to carry as hidden fields or a submit drops them. A filter
    #               with a field of its own (the search, the typed dates) carries
    #               nothing. :period and :status carry their effective value and
    #               render it themselves (_filter_line).
    Filter = Data.define(:key, :kind, :attributes, :removal, :state_keys, :carried) do
      # Does it differ from what an untouched page shows? The mobile badge
      # counts these, and a reset is only offered while one does.
      def deviates?(state)
        case kind
        when :period then ListPeriod.normalize_for_list(state[:date_range]) != ListPeriod::LIST_DEFAULT
        when :status then Array(state[:status_filters]).sort != TimeSession::DEFAULT_STATUS_FILTERS.sort
        else set?(state)
        end
      end

      # Does it stand where the reset leads (TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS)?
      def neutral?(state)
        neutral = TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS
        case kind
        when :period then state[:date_range].to_s == neutral[:date_range]
        when :status then Array(state[:status_filters]).sort == neutral[:status_filters].sort
        else !set?(state)
        end
      end

      def set?(state)
        state_keys.any? { |state_key| state[state_key].present? }
      end

      def plain?
        kind == :plain
      end
    end

    # One subject pill for two ids, see TimeSession::SUBJECT_FILTER_PARAMS.
    SUBJECT_PARAMS = TimeSession::SUBJECT_FILTER_PARAMS
    SUBJECT_REMOVAL = SUBJECT_PARAMS.index_with { nil }.freeze

    # The order is the order the filter row is read in, which is the order the
    # empty state offers its removals in.
    ALL = [
      # ⚠️ The period removal OPENS the period instead of clearing the key. An
      # absent date_range is not "all time", it is the default month.
      Filter.new(key: :period, kind: :period,
                 attributes: %i[start_date end_date],
                 removal: { 'date_range' => 'all', 'start_date' => nil, 'end_date' => nil }.freeze,
                 state_keys: [], carried: []),
      # Removing the project takes the subject with it: a subject belongs to a
      # project, and a subject left standing alone narrows to one project anyway.
      # The same goes for a ticket status VALUE (step 3b): it is a word of one
      # project. The ticket phase means the same everywhere and stays.
      Filter.new(key: :project, kind: :plain,
                 attributes: %i[project_id_filter],
                 removal: { 'project_id_filter' => nil, 'ticket_status' => nil }.merge(SUBJECT_REMOVAL).freeze,
                 state_keys: %i[project], carried: %w[project_id_filter]),
      Filter.new(key: :subject, kind: :plain,
                 attributes: SUBJECT_PARAMS.map(&:to_sym),
                 removal: SUBJECT_REMOVAL,
                 state_keys: %i[ticket meeting], carried: SUBJECT_PARAMS),
      Filter.new(key: :billing, kind: :plain,
                 attributes: %i[time_session_group_id],
                 removal: { 'time_session_group_id' => nil }.freeze,
                 state_keys: %i[group], carried: %w[time_session_group_id]),
      # ⚠️ The status removal SETS all three states instead of clearing the key.
      # An absent status_filters is not "all three", it is the default that hides
      # billed. billing_status, the legacy single-value param, goes with them.
      Filter.new(key: :status, kind: :status,
                 attributes: %i[status_filters billing_status],
                 removal: { 'status_filters' => TimeSession::BILLING_STATUS_FILTERS, 'billing_status' => nil }.freeze,
                 state_keys: [], carried: []),
      Filter.new(key: :creator, kind: :plain,
                 attributes: %i[creator_id],
                 removal: { 'creator_id' => nil }.freeze,
                 state_keys: %i[creator_id], carried: %w[creator_id]),
      # The tag on the booking OR on its ticket (plan step 2, variant C).
      Filter.new(key: :tag, kind: :plain,
                 attributes: %i[tag_id],
                 removal: { 'tag_id' => nil }.freeze,
                 state_keys: %i[tag], carried: %w[tag_id]),
      # The status of the booking's ticket: a phase (plan step 3a) or, once a
      # project is chosen, one of its own values (step 3b). ONE unit with two
      # parameters, like the subject: one pill, and choosing one replaces the
      # other. Set by the raw values: an unknown phase or value empties the
      # list, so it is a filter in force even though it has no word to show
      # (the pill reads the valid phase or the offered value only).
      Filter.new(key: :ticket_phase, kind: :plain,
                 attributes: %i[ticket_phase ticket_status],
                 removal: { 'ticket_phase' => nil, 'ticket_status' => nil }.freeze,
                 state_keys: %i[ticket_phase ticket_status], carried: %w[ticket_phase ticket_status]),
      Filter.new(key: :search, kind: :plain,
                 attributes: %i[search],
                 removal: { 'search' => nil }.freeze,
                 state_keys: %i[search], carried: [])
    ].freeze

    BY_KEY = ALL.index_by(&:key).freeze
    KEYS = BY_KEY.keys.freeze

    class << self
      def removal(key)
        BY_KEY.fetch(key).removal
      end

      # key => removal, for every filter.
      def removals
        ALL.to_h { |filter| [filter.key, filter.removal] }
      end

      # The service attributes of the :plain filters, read off the request. Their
      # attribute names ARE their parameter names. The period and the status are
      # not in here: the controller resolves both first (a preset into bounds,
      # the default states), and hands the resolved values in beside these.
      def plain_attributes_from(params)
        ALL.select(&:plain?).flat_map(&:attributes).index_with { |attribute| params[attribute] }
      end

      # A record id off the address, read the way the QUERY reads it: through
      # the uuid type, which the filter service's where() casts with too (every
      # id filter of this list is a uuid column, creator_id and tag_id alike). That type accepts capitals, a missing hyphen and braces, and
      # rejects blanks around the id. The page compares ids in Ruby; with a rule
      # of its own it named Anna over a list the database had emptied, or left
      # her unnamed over a list of her rows (two reviews, 29.09.2026).
      #
      # A value the type rejects passes unchanged. The query turns it into
      # "= NULL" and lists nothing, and here it stays a filter that is set and
      # names nobody, so the two still agree. So does anything that is not a
      # String (an array, a hash).
      def normalize_id(value)
        return value unless value.is_a?(String)

        TimeSession.type_for_attribute(:creator_id).cast(value) || value
      end

      # The parameters the filter form carries as hidden fields.
      def carried_params
        ALL.flat_map(&:carried)
      end
    end
  end
end
