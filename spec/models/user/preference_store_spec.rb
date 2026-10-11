# frozen_string_literal: true

require 'rails_helper'

# Specs for User::PreferenceStore — the foundational JSONB preferences store
# extracted from the User god-class (user.rb split, slice 1/7). Every later
# slice (sidebar pins, org colors, ticket notifications) reads and writes
# through this object, so its contracts are load-bearing for the whole split.
#
# WHAT THIS GUARDS
# All access to the users.preferences JSONB column funnels through here. The
# slice is a pure refactoring, so these are CHARACTERIZATION tests: they pin the
# behaviour the legacy User methods already had, not new requirements.
#
# WHY THE EXAMPLES LOOK THE WAY THEY DO
#   - #get uses `||`, so a stored `false` falls back to the default — pinned
#     explicitly because callers must not store booleans expecting false to win;
#   - the writers (#set / #set! / #update) return the truthiness of user.save
#     (controllers branch on it) and persist via merge + FULL reassignment,
#     never in-place, or JSONB dirty tracking would not fire — both pinned;
#   - #set! is the raise-on-failure twin of #set (added in slice 4 for
#     User::NotificationSettings#update); its raise example is the single point
#     where it must behave differently from #set;
#   - the "JSONB column contract" block pins the DB default `{}` and the NOT
#     NULL constraint that every reader's `preferences.dig(...)` silently
#     relies on — without it the whole store would NoMethodError on nil.
RSpec.describe User::PreferenceStore, type: :model do
  let(:user) { create(:user) }
  let(:store) { user.preference_store }

  describe 'memoization' do
    # Invariant from the split plan (doc/user_split_plan.md §5.3/8): the store
    # shares the lifetime of the other per-instance caches — without `||=`
    # every access would build a fresh instance (this mutant survived the
    # first review pass).
    it 'returns the same store instance for the same user instance' do
      expect(user.preference_store).to equal(user.preference_store)
    end
  end

  describe 'onboarding banner dismissal (per user + organisation)' do
    let(:org_a) { create(:organisation) }
    let(:org_b) { create(:organisation) }

    it 'defaults to not dismissed' do
      expect(store.onboarding_banner_dismissed?(org_a)).to be(false)
    end

    it 'scopes the dismissal to the given organisation' do
      store.dismiss_onboarding_banner!(org_a)

      expect(store.onboarding_banner_dismissed?(org_a)).to be(true)
      expect(store.onboarding_banner_dismissed?(org_b)).to be(false)
    end

    # JSONB merge contract: dismissing must MERGE into the slot and into the
    # overall preferences — a write that replaces either hash wholesale would
    # silently wipe unrelated preferences (or the other org's dismissal).
    it 'preserves other org dismissals and unrelated preference keys' do
      store.set!('items_per_page', 50)
      store.dismiss_onboarding_banner!(org_a)
      store.dismiss_onboarding_banner!(org_b)

      reloaded = user.reload.preference_store
      expect(reloaded.onboarding_banner_dismissed?(org_a)).to be(true)
      expect(reloaded.onboarding_banner_dismissed?(org_b)).to be(true)
      expect(reloaded.items_per_page_preference).to eq(50)
    end
  end

  describe 'overview widget period' do
    it 'defaults to the canonical default when nothing is stored' do
      expect(store.overview_widget_period('my_week_stats')).to eq(Overview::TimePeriod::DEFAULT)
    end

    it 'stores and reads back a period per widget key' do
      store.set_overview_widget_period('my_week_stats', 'this_month')
      expect(user.reload.preference_store.overview_widget_period('my_week_stats')).to eq('this_month')
    end

    it 'keeps each widget’s choice independent (deep merge, no clobber)' do
      store.set_overview_widget_period('my_week_stats', 'this_month')
      store.set_overview_widget_period('my_week_chart', 'this_quarter')

      reloaded = user.reload.preference_store
      expect(reloaded.overview_widget_period('my_week_stats')).to eq('this_month')
      expect(reloaded.overview_widget_period('my_week_chart')).to eq('this_quarter')
    end

    it 'normalises an unknown stored or incoming value to the default' do
      store.set_overview_widget_period('my_week_stats', 'bogus')
      expect(store.overview_widget_period('my_week_stats')).to eq(Overview::TimePeriod::DEFAULT)
    end
  end

  describe 'cockpit settings' do
    describe 'defaults (nothing stored — read straight off a fresh user, NOT the factory)' do
      it 'shows actions and todos by default' do
        expect(store.cockpit_show_actions?).to be(true)
        expect(store.cockpit_show_todos?).to be(true)
      end

      it 'defaults importance to "important" and layout to "stacked"' do
        expect(store.cockpit_importance).to eq('important')
        expect(store.cockpit_layout).to eq('stacked')
      end
    end

    describe 'round-trip' do
      # The key mutation guard: a stored `false` must read back as false. If the flag reader used
      # #get (`preferences[k] || default`), `false || true` would wrongly yield the default true.
      it 'reads back a stored false for the toggles (not the default true)' do
        store.update('cockpit_show_actions' => false, 'cockpit_show_todos' => false)

        reloaded = user.reload.preference_store
        expect(reloaded.cockpit_show_actions?).to be(false)
        expect(reloaded.cockpit_show_todos?).to be(false)
      end

      # Iterate over the CONSTANTS so shrinking an allow-list turns a test red.
      User::PreferenceStore::COCKPIT_IMPORTANCE_LEVELS.each do |level|
        it "reads back importance #{level.inspect}" do
          store.update('cockpit_importance' => level)
          expect(user.reload.preference_store.cockpit_importance).to eq(level)
        end
      end

      User::PreferenceStore::COCKPIT_LAYOUTS.each do |layout|
        it "reads back layout #{layout.inspect}" do
          store.update('cockpit_layout' => layout)
          expect(user.reload.preference_store.cockpit_layout).to eq(layout)
        end
      end
    end

    describe 'read-side normalisation (defense in depth)' do
      it 'falls back to the default importance for an unknown stored value' do
        store.update('cockpit_importance' => 'garbage')
        expect(store.cockpit_importance).to eq('important')
      end

      it 'falls back to the default layout for an unknown stored value' do
        store.update('cockpit_layout' => 'pizza')
        expect(store.cockpit_layout).to eq('stacked')
      end

      it 'casts stored string booleans for the toggles ("0"/"1")' do
        store.update('cockpit_show_actions' => '0', 'cockpit_show_todos' => '1')

        reloaded = user.reload.preference_store
        expect(reloaded.cockpit_show_actions?).to be(false)
        expect(reloaded.cockpit_show_todos?).to be(true)
      end
    end
  end

  describe '#get' do
    it 'returns the stored value for string and symbol keys' do
      user.update!(preferences: { 'items_per_page' => 50 })
      expect(store.get('items_per_page')).to eq(50)
      expect(store.get(:items_per_page)).to eq(50)
    end

    it 'returns the default when the key is missing' do
      user.update!(preferences: {})
      expect(store.get('missing', 'fallback')).to eq('fallback')
    end

    it 'returns nil without an explicit default' do
      user.update!(preferences: {})
      expect(store.get('missing')).to be_nil
    end

    it 'returns the default when the stored value is false (|| semantics)' do
      # Characterization: `get` uses `||`, so falsy stored values fall back to
      # the default. Callers must not store booleans expecting false to win.
      user.update!(preferences: { 'flag' => false })
      expect(store.get('flag', 'fallback')).to eq('fallback')
    end
  end

  describe '#set' do
    it 'persists the value under a stringified key and returns true' do
      expect(store.set(:items_per_page, 50)).to be true
      expect(user.reload.preferences['items_per_page']).to eq(50)
    end

    it 'keeps other preferences untouched' do
      user.update!(preferences: { 'post_direction' => 'reverse' })
      store.set('items_per_page', 50)
      expect(user.reload.preferences).to include(
        'post_direction' => 'reverse',
        'items_per_page' => 50
      )
    end

    it 'returns false when the user cannot be saved' do
      allow(user).to receive(:save).and_return(false)
      expect(store.set('items_per_page', 50)).to be false
    end

    it 'overwrites an existing value for the same key (new value wins)' do
      # Kills a reversed merge (`{key => value}.merge(preferences)`), which
      # the disjoint-keys example above cannot catch.
      user.update!(preferences: { 'items_per_page' => 20 })
      store.set('items_per_page', 50)
      expect(user.reload.preferences['items_per_page']).to eq(50)
    end

    it 'makes the new value readable in-memory without reload' do
      # Callers like User::OrgColorSettings#set read right after writing; the
      # write must be visible on the same instance without a DB round-trip.
      store.set('items_per_page', 50)
      expect(store.get('items_per_page')).to eq(50)
    end
  end

  # set! is the raise-on-failure twin of set (added in the slice-4 split). It
  # exists because the legacy ticket-notification writer persisted with save!,
  # and User::NotificationSettings#update relies on that raise instead of a
  # silently swallowed false. These examples mirror the #set block so the two
  # writers stay behaviourally identical EXCEPT for the failure mode — the
  # raise example below is the one that must differ from #set.
  describe '#set!' do
    it 'persists the value under a stringified key and returns true' do
      expect(store.set!(:items_per_page, 50)).to be true
      expect(user.reload.preferences['items_per_page']).to eq(50)
    end

    it 'keeps sibling preference slots untouched' do
      user.update!(preferences: { 'post_direction' => 'reverse' })
      store.set!('items_per_page', 50)
      expect(user.reload.preferences).to include(
        'post_direction' => 'reverse',
        'items_per_page' => 50
      )
    end

    it 'overwrites an existing value for the same key (new value wins)' do
      # Symmetric to the #set overwrite test: kills a reversed merge
      # ({key => value}.merge(preferences)) in set! directly, instead of only
      # transitively via User::NotificationSettings#update.
      user.update!(preferences: { 'items_per_page' => 20 })
      store.set!('items_per_page', 50)
      expect(user.reload.preferences['items_per_page']).to eq(50)
    end

    it 'raises and persists nothing when the user cannot be saved (save! instead of save)' do
      # The whole point of set! over set: callers like
      # User::NotificationSettings#update rely on the raise instead of a
      # silently swallowed false.
      user.email = ''

      expect { store.set!('items_per_page', 50) }
        .to raise_error(ActiveRecord::RecordInvalid)

      expect(user.reload.preferences['items_per_page']).to be_nil
    end
  end

  describe '#update' do
    it 'updates existing preferences' do
      user.update!(preferences: { 'items_per_page' => 20 })

      new_prefs = { 'items_per_page' => 50, 'new_setting' => 'value' }
      result = store.update(new_prefs)

      expect(result).to be true
      expect(user.reload.preferences).to include(
        'items_per_page' => 50,
        'new_setting' => 'value'
      )
    end

    it 'deep merges nested preferences' do
      user.update!(preferences: {
                     'date_display' => {
                       'global_format' => 'relative',
                       'areas' => { 'posts' => 'inherit' }
                     }
                   })

      new_prefs = {
        'date_display' => {
          'global_format' => 'german',
          'areas' => { 'tickets' => 'relative' }
        }
      }

      store.update(new_prefs)

      expect(user.reload.preferences).to include(
        'date_display' => {
          'global_format' => 'german',
          'areas' => {
            'posts' => 'inherit',
            'tickets' => 'relative'
          }
        }
      )
    end

    it 'handles validation errors' do
      # Mock a validation error
      allow(user).to receive(:save).and_return(false)
      allow(user).to receive(:valid?).and_return(false)

      result = store.update({ 'items_per_page' => 'invalid' })
      expect(result).to be false
    end

    it 'stringifies symbol keys before the deep merge (nested siblings survive)' do
      # The JSONB attribute cast stringifies keys on assignment anyway, so a
      # flat symbol write cannot distinguish this decision point (verified via
      # mutation probe). It only bites on nested input: without stringify_keys
      # a symbol top-level key does not deep-merge into its string twin — the
      # JSON round-trip then keeps only the last duplicate and sibling keys
      # like `areas` are silently lost.
      user.update!(preferences: {
                     'date_display' => {
                       'global_format' => 'relative',
                       'areas' => { 'posts' => 'inherit' }
                     }
                   })

      result = nil
      expect do
        result = store.update({ date_display: { global_format: 'german' } })
      end.not_to output(/duplicate key/).to_stderr

      expect(result).to be true
      expect(user.preferences.dig('date_display', 'global_format')).to eq('german')
      expect(user.preferences.dig('date_display', 'areas')).to eq('posts' => 'inherit')
    end

    it 'accepts permitted controller parameters without losing nested preferences' do
      user.update!(preferences: { 'date_display' => { 'areas' => { 'posts' => 'inherit' } } })
      params = ActionController::Parameters.new(date_display: { global_format: 'german' })
                                           .permit(date_display: [:global_format])

      expect(store.update(params)).to be true
      expect(user.reload.preferences.fetch('date_display')).to include(
        'global_format' => 'german', 'areas' => { 'posts' => 'inherit' }
      )
    end

    it 'initializes preferences hash if empty' do
      user.update!(preferences: {})

      result = store.update({ 'items_per_page' => 30 })

      expect(result).to be true
      expect(user.reload.preferences).to eq({ 'items_per_page' => 30 })
    end
  end

  describe '#org_key' do
    let(:organisation) { create(:organisation) }

    it 'returns the id as string for an Organisation object' do
      expect(store.org_key(organisation)).to eq(organisation.id.to_s)
    end

    it 'stringifies a raw id' do
      expect(store.org_key(organisation.id)).to eq(organisation.id.to_s)
    end
  end

  # Facade on User (external contract): items_per_page_preference is called
  # directly on the user by Pageable, ApplicationController, ApplicationHelper
  # and views — these examples therefore deliberately go through user.…
  describe '#items_per_page_preference' do
    it 'returns default value when preferences is empty' do
      user.update!(preferences: {})
      expect(user.items_per_page_preference).to eq(20)
    end

    it 'returns default value when items_per_page is not set' do
      user.update!(preferences: {})
      expect(user.items_per_page_preference).to eq(20)
    end

    it 'returns stored value when set' do
      user.update!(preferences: { 'items_per_page' => 50 })
      expect(user.items_per_page_preference).to eq(50)
    end

    it 'converts string values to integers' do
      user.update!(preferences: { 'items_per_page' => '100' })
      expect(user.items_per_page_preference).to eq(100)
    end
  end

  describe '#date_display_format' do
    it 'returns relative by default' do
      user.update!(preferences: {})
      expect(store.date_display_format).to eq('relative')
    end

    it 'returns global format when set' do
      user.update!(preferences: {
                     'date_display' => { 'global_format' => 'german' }
                   })
      expect(store.date_display_format).to eq('german')
    end
  end

  describe '#date_format_for_area' do
    before do
      user.update!(preferences: {
                     'date_display' => {
                       'global_format' => 'german',
                       'areas' => {
                         'posts' => 'relative',
                         'ticket_header' => 'inherit'
                       }
                     }
                   })
    end

    it 'returns area-specific format when set' do
      expect(store.date_format_for_area('posts')).to eq('relative')
    end

    it 'returns global format when area inherits' do
      expect(store.date_format_for_area('ticket_header')).to eq('german')
    end

    it 'returns global format when area not configured' do
      expect(store.date_format_for_area('unknown_area')).to eq('german')
    end

    it 'handles nil area parameter' do
      expect(store.date_format_for_area(nil)).to eq('german')
    end

    it 'accepts symbol area names (key is stringified)' do
      expect(store.date_format_for_area(:posts)).to eq('relative')
    end
  end

  # Facade on User (external contract): date_strftime_format is called
  # directly on the user by ApplicationHelper (display_time & friends) —
  # these examples therefore deliberately go through user.…
  describe '#date_strftime_format' do
    context 'with relative format' do
      before do
        user.update!(preferences: {
                       'date_display' => { 'global_format' => 'relative' }
                     })
      end

      it 'returns nil for relative format' do
        expect(user.date_strftime_format).to be_nil
      end

      it 'returns nil for area with relative format' do
        user.preferences['date_display']['areas'] = { 'posts' => 'relative' }
        expect(user.date_strftime_format('posts')).to be_nil
      end
    end

    context 'with absolute formats' do
      before do
        user.update!(preferences: {
                       'date_display' => {
                         'global_format' => 'german',
                         'custom_format' => '%Y/%m/%d %H:%M'
                       }
                     })
      end

      it 'returns German format string' do
        expect(user.date_strftime_format).to eq('%d.%m.%Y %H:%M')
      end

      it 'returns international format string' do
        user.preferences['date_display']['global_format'] = 'international'
        expect(user.date_strftime_format).to eq('%Y-%m-%d %H:%M')
      end

      it 'returns custom format string' do
        user.preferences['date_display']['global_format'] = 'custom'
        expect(user.date_strftime_format).to eq('%Y/%m/%d %H:%M')
      end
    end

    context 'with custom format but no stored custom_format' do
      it 'falls back to the default custom format' do
        user.update!(preferences: { 'date_display' => { 'global_format' => 'custom' } })
        expect(user.date_strftime_format).to eq('%d.%m.%Y %H:%M')
      end
    end

    context 'with area-specific custom formats' do
      before do
        user.update!(preferences: {
                       'date_display' => {
                         'global_format' => 'german',
                         'areas' => { 'posts' => 'custom' },
                         'areas_custom' => { 'posts' => '%d-%m-%Y' }
                       }
                     })
      end

      it 'returns area custom format when area uses custom' do
        expect(user.date_strftime_format('posts')).to eq('%d-%m-%Y')
      end

      it 'returns exact user-specified format without time when custom' do
        user.update!(preferences: {
                       'date_display' => {
                         'areas' => { 'tickets' => 'custom' },
                         'areas_custom' => { 'tickets' => '%d.%m.%Y' }
                       }
                     })
        expect(user.date_strftime_format('tickets')).to eq('%d.%m.%Y')
      end

      it 'falls back to global custom format if area custom not found' do
        user.preferences['date_display']['areas']['tickets'] = 'custom'
        user.preferences['date_display']['custom_format'] = '%Y.%m.%d'
        expect(user.date_strftime_format('tickets')).to eq('%Y.%m.%d')
      end

      it 'falls back to the global custom format when the area custom format is blank' do
        # `.presence ||` (not a bare `||`): an empty string must fall through
        # to the global custom format as well.
        user.update!(preferences: {
                       'date_display' => {
                         'custom_format' => '%Y.%m.%d',
                         'areas' => { 'posts' => 'custom' },
                         'areas_custom' => { 'posts' => '' }
                       }
                     })
        expect(user.date_strftime_format('posts')).to eq('%Y.%m.%d')
      end
    end
  end

  describe '#post_direction_preference' do
    it 'returns chronological by default when preferences is empty' do
      user.update!(preferences: {})
      expect(store.post_direction_preference).to eq('chronological')
    end

    it 'returns chronological by default when post_direction is not set' do
      user.update!(preferences: {})
      expect(store.post_direction_preference).to eq('chronological')
    end

    it 'returns stored value when set to reverse' do
      user.update!(preferences: { 'post_direction' => 'reverse' })
      expect(store.post_direction_preference).to eq('reverse')
    end

    it 'returns stored value when explicitly set to chronological' do
      user.update!(preferences: { 'post_direction' => 'chronological' })
      expect(store.post_direction_preference).to eq('chronological')
    end
  end

  describe '#prefers_reverse_timeline?' do
    it 'returns false by default' do
      user.update!(preferences: {})
      expect(store.prefers_reverse_timeline?).to be false
    end

    it 'returns false when set to chronological' do
      user.update!(preferences: { 'post_direction' => 'chronological' })
      expect(store.prefers_reverse_timeline?).to be false
    end

    it 'returns true when set to reverse' do
      user.update!(preferences: { 'post_direction' => 'reverse' })
      expect(store.prefers_reverse_timeline?).to be true
    end

    it 'returns false for unknown direction values' do
      # Kills the `direction != 'chronological'` mutant, which the
      # chronological/reverse pair alone lets survive.
      user.update!(preferences: { 'post_direction' => 'sideways' })
      expect(store.prefers_reverse_timeline?).to be false
    end
  end

  describe '#description_collapse_preference' do
    it 'returns unset by default when preferences is empty' do
      user.update!(preferences: {})
      expect(store.description_collapse_preference).to eq('unset')
    end

    it 'returns the stored value when set to auto' do
      user.update!(preferences: { 'description_collapse' => 'auto' })
      expect(store.description_collapse_preference).to eq('auto')
    end

    it 'returns the stored value when set to always_full' do
      user.update!(preferences: { 'description_collapse' => 'always_full' })
      expect(store.description_collapse_preference).to eq('always_full')
    end
  end

  describe '#collapse_known_ticket_descriptions?' do
    it 'collapses by default (unanswered state)' do
      user.update!(preferences: {})
      expect(store.collapse_known_ticket_descriptions?).to be true
    end

    it 'collapses when set to auto' do
      user.update!(preferences: { 'description_collapse' => 'auto' })
      expect(store.collapse_known_ticket_descriptions?).to be true
    end

    it 'does not collapse when set to always_full' do
      user.update!(preferences: { 'description_collapse' => 'always_full' })
      expect(store.collapse_known_ticket_descriptions?).to be false
    end

    it 'collapses for unknown values (only always_full opts out)' do
      # Kills a `== 'auto'` mutant: any non-always_full value must still collapse,
      # otherwise the unanswered default would stop collapsing.
      user.update!(preferences: { 'description_collapse' => 'sideways' })
      expect(store.collapse_known_ticket_descriptions?).to be true
    end
  end

  describe '#meeting_detection_mode_preference' do
    # Gespräche Slice 5: data-sovereignty default is OFFLINE — the LLM mode is
    # an explicit choice. Read-side whitelist mirrors cockpit_importance: the
    # JSONB has no model validation, so a crafted/stale value must read as the
    # canonical default (fail-closed towards "nothing leaves the browser").
    it "returns 'offline' by default when nothing is stored" do
      user.update!(preferences: {})
      expect(store.meeting_detection_mode_preference).to eq('offline')
    end

    it "returns 'ai' when stored" do
      user.update!(preferences: { 'meeting_detection_mode' => 'ai' })
      expect(store.meeting_detection_mode_preference).to eq('ai')
    end

    it "falls back to 'offline' for an unknown stored value" do
      user.update!(preferences: { 'meeting_detection_mode' => 'llm_always' })
      expect(store.meeting_detection_mode_preference).to eq('offline')
    end
  end

  describe '#name_display_mode' do
    # Viewer-side name display (doc/user_display_name_avatar_plan.md, S1).
    # Read-side whitelist mirrors meeting_detection_mode_preference: the JSONB
    # has no model validation, so a crafted/stale value must read as 'full' —
    # the default that keeps the app looking exactly as before the feature.
    it "returns 'full' by default when nothing is stored" do
      user.update!(preferences: {})
      expect(store.name_display_mode).to eq('full')
    end

    it 'returns every whitelisted stored value verbatim' do
      User::PreferenceStore::NAME_DISPLAY_MODES.each do |mode|
        user.update!(preferences: { 'name_display' => mode })
        expect(store.name_display_mode).to eq(mode)
      end
    end

    it "falls back to 'full' for an unknown stored value" do
      user.update!(preferences: { 'name_display' => 'gravatar' })
      expect(store.name_display_mode).to eq('full')
    end
  end

  describe '#description_collapse_answered?' do
    it 'is false by default (unanswered → info box keeps showing)' do
      user.update!(preferences: {})
      expect(store.description_collapse_answered?).to be false
    end

    # Boundary across the three states: 'unset' is the only unanswered one.
    it 'is true once set to auto' do
      user.update!(preferences: { 'description_collapse' => 'auto' })
      expect(store.description_collapse_answered?).to be true
    end

    it 'is true once set to always_full' do
      user.update!(preferences: { 'description_collapse' => 'always_full' })
      expect(store.description_collapse_answered?).to be true
    end
  end

  describe 'JSONB column contract' do
    it 'defaults to an empty hash on insert (DB default, not factory-provided)' do
      # The user factory does not set preferences; this pins the column
      # default `{}` and proves every reader yields its documented default
      # on a fresh user without the explicit resets used elsewhere.
      fresh = create(:user)

      expect(fresh.reload.preferences).to eq({})
      expect(fresh.preference_store.items_per_page_preference).to eq(20)
      expect(fresh.preference_store.post_direction_preference).to eq('chronological')
      expect(fresh.preference_store.date_display_format).to eq('relative')
      expect(fresh.preference_store.description_collapse_preference).to eq('unset')
    end

    it 'rejects explicit nil at the DB layer (NOT NULL constraint)' do
      # The store assumes preferences is never nil; this pins the DB
      # guarantee backing that assumption.
      user.preferences = nil
      expect { user.save!(validate: false) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe '#using_global_date_format_for_all?' do
    let(:all_inherit) do
      {
        'posts' => 'inherit',
        'ticket_header' => 'inherit',
        'ticket_list_large' => 'inherit',
        'ticket_list_compact' => 'inherit',
        'activity_logs' => 'inherit'
      }
    end

    it 'returns true when all five areas inherit' do
      user.update!(preferences: { 'date_display' => { 'areas' => all_inherit } })
      expect(store.using_global_date_format_for_all?).to be true
    end

    # Positive iteration over the five-area whitelist: if any area is removed
    # from the check inside the store, exactly one of these examples keeps the
    # method truthy and turns red — a single "one area differs" example would
    # let such a shrink survive.
    %w[posts ticket_header ticket_list_large ticket_list_compact activity_logs].each do |area|
      it "returns false when only #{area} has an own format" do
        user.update!(preferences: {
                       'date_display' => { 'areas' => all_inherit.merge(area => 'german') }
                     })
        expect(store.using_global_date_format_for_all?).to be false
      end
    end

    it 'returns false when areas are not configured' do
      user.update!(preferences: {})
      expect(store.using_global_date_format_for_all?).to be false
    end
  end
end
