# frozen_string_literal: true

require 'rails_helper'

# Specs for User::OrgColorSettings — the per-user/per-org org recognition color,
# extracted from the User god class (user.rb split, slice 3/7). Reachable
# via user.org_colors (no facade). The pure color rules live in
# OrgColor; here the DB wiring, the membership hook and the auto-assignment.
# Moved unchanged from spec/models/user_org_color_spec.rb — pure refactoring,
# i.e. CHARACTERIZATION: existing behavior is pinned, not a new feature.
#
# WHY THE EXAMPLES LOOK THE WAY THEY DO
#   - Three-state per (user, org): Hex / OFF (deliberately off, distinguishable
#     from absent) / auto (entry removed). Each state is pinned individually,
#     because OFF and "absent" would otherwise collapse together;
#   - the >=2-orgs gate counts only ACTIVE memberships — the "1 active +
#     1 inactive" cases kill a count of ALL memberships;
#   - the org_count memoization is checked via query-count guards (exactly
#     ONE COUNT when resolving many orgs, plus the 0-orgs boundary): without the
#     memo this would be a silent COUNT N+1 on every page;
#   - org_key normalizes object AND ID to the same slot; mutators return
#     user.save and write via preference_store (merge + full
#     reassignment), so that foreign preference slots survive;
#   - the STRING "auto" is deliberately pinned literally as a trap (only the
#     symbol :auto resets) — characterization, not an endorsement;
#   - PREF_KEY is historically 'sidebar_colors' (production data) — do NOT
#     rename.
RSpec.describe User::OrgColorSettings, type: :model do
  let(:user) { create(:user) }

  # Adds a user (default: the let-user) active/inactive to a new org, returns the org.
  def add_org(target = user, active: true)
    org = create(:organisation)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: target, organisation: org, active: active)
    end
    org
  end

  describe 'memoization' do
    # Invariant from the split plan (user split, slice 3): without `||=` on
    # User#org_colors every access would build a fresh instance — and a fresh
    # instance per call re-fires the internal org COUNT query (see the
    # query-count guard below).
    it 'returns the same instance for the same user instance' do
      expect(user.org_colors).to equal(user.org_colors)
    end
  end

  describe '#set (3-Zustand)' do
    let(:org) { add_org }

    it 'speichert einen Hex' do
      user.org_colors.set(org, '#dbeafe')
      expect(user.reload.org_colors.setting_for(org)).to eq('#dbeafe')
    end

    it 'speichert OFF (bewusst aus) — unterscheidbar von abwesend' do
      user.org_colors.set(org, OrgColor::OFF)
      expect(user.reload.org_colors.setting_for(org)).to eq(OrgColor::OFF)
    end

    it 'entfernt den Eintrag bei :auto / nil / "" (zurueck auf automatisch)' do
      # preference_store.set updates preferences in-memory -> readable without reload
      # (a reload per iteration would make the Prosopite N+1 guard flag a multi-load).
      [:auto, nil, ''].each do |reset|
        user.org_colors.set(org, '#dbeafe')
        user.org_colors.set(org, reset)
        expect(user.org_colors.setting_for(org)).to be_nil, "erwartet nil nach #{reset.inspect}"
      end
    end

    # Invariant 6 (org_key normalization): organisation OBJECT or ID hit the
    # same slot. Kills the mutant that bypasses store.org_key with
    # `organisation.id.to_s` (a raw UUID string has no #id -> NoMethodError).
    it 'akzeptiert eine Organisations-ID anstelle des Objekts (gleicher Slot)' do
      user.org_colors.set(org.id, '#dbeafe')
      expect(user.org_colors.setting_for(org)).to eq('#dbeafe')
      expect(user.org_colors.setting_for(org.id)).to eq('#dbeafe')
    end

    # Invariant 7: mutators return the truthiness of user.save (controllers
    # may branch on it; also kills a silent save -> save! swap, which would
    # raise instead of returning false).
    it 'gibt das save-Ergebnis zurueck; ein Fehlschlag persistiert nicht' do
      expect(user.org_colors.set(org, '#dbeafe')).to be true

      user.email = nil # invalidate -> save returns false
      expect(user.org_colors.set(org, OrgColor::OFF)).to be false
      expect(user.reload.org_colors.setting_for(org)).to eq('#dbeafe')
    end

    # Characterization, NOT endorsement (identical in the pre-split code):
    # the STRING 'auto' is neither blank nor the :auto symbol -> it is stored
    # literally, assign_defaults then sees the key as "decided" and never
    # auto-colors again, effective_color yields nil. App-safe today because
    # the appearances controller whitelists and maps to the :auto symbol;
    # normalizing here would be a behavior change (later slice / product call).
    it 'speichert den STRING "auto" woertlich (Falle gepinnt, Symbol-only-Reset)' do
      user.org_colors.set(org, 'auto')
      expect(user.org_colors.setting_for(org)).to eq('auto')
    end
  end

  describe 'org count (gate input)' do
    # The count is now a private memo inside the PORO — observed through the
    # gate instead of being tested directly: 2 active + 1 inactive
    # memberships still pass the >=2 gate (the inactive one must not be
    # needed). The kill case for counting ALL memberships is the
    # 1-active-+-1-inactive example further down (gate would wrongly open).
    it 'counts only ACTIVE memberships, observed through the gate' do
      org = add_org(active: true)
      add_org(active: true)
      add_org(active: false)
      user.reload.org_colors.set(org, '#dbeafe')
      expect(user.org_colors.effective_color(org)).to eq('#dbeafe')
    end
  end

  describe '#effective_color (Gate + OFF zentral)' do
    it 'gibt nil bei nur einer Org — auch mit gesetzter Farbe' do
      org = add_org
      user.org_colors.set(org, '#dbeafe')
      expect(user.reload.org_colors.effective_color(org)).to be_nil
    end

    it 'gibt den Hex ab 2 Orgs' do
      org = add_org
      other = add_org
      user.org_colors.set(org, '#dbeafe')
      expect(user.reload.org_colors.effective_color(org)).to eq('#dbeafe')
      # the other org is auto-colored via the hook -> also a color (just not the same one)
      expect(user.reload.org_colors.effective_color(other)).to be_present
    end

    it 'gibt nil bei OFF, auch mit 2 Orgs' do
      org = add_org
      add_org
      user.org_colors.set(org, OrgColor::OFF)
      expect(user.reload.org_colors.effective_color(org)).to be_nil
    end

    it 'zaehlt nur AKTIVE Orgs fuers Gate: 1 aktiv + 1 inaktiv + gesetzte Farbe -> nil' do
      # Kills org_count via memberships.active -> organisations(all): with a
      # total count it would be 2 and the color would wrongly become visible.
      org = add_org(active: true)
      add_org(active: false)
      user.org_colors.set(org, '#dbeafe')
      expect(user.reload.org_colors.effective_color(org)).to be_nil
    end
  end

  describe '#ensure_defaults!' do
    it 'tut nichts bei <2 Orgs' do
      org = add_org
      user.reload.org_colors.ensure_defaults!
      expect(user.reload.org_colors.setting_for(org)).to be_nil
    end

    it 'weist ab 2 Orgs distinkte Farben zu' do
      a = add_org
      b = add_org
      user.reload.org_colors.ensure_defaults!
      ca = user.reload.org_colors.setting_for(a)
      cb = user.org_colors.setting_for(b)
      expect(OrgColor.hex?(ca)).to be(true)
      expect(OrgColor.hex?(cb)).to be(true)
      expect(ca).not_to eq(cb)
    end

    it 'laesst OFF unangetastet (Aus bleibt aus)' do
      a = add_org
      add_org
      user.org_colors.set(a, OrgColor::OFF)
      user.reload.org_colors.ensure_defaults!
      expect(user.reload.org_colors.setting_for(a)).to eq(OrgColor::OFF)
    end

    it 'laesst eine eigene Farbe unangetastet' do
      a = add_org
      add_org
      user.org_colors.set(a, '#cffafe')
      user.reload.org_colors.ensure_defaults!
      expect(user.reload.org_colors.setting_for(a)).to eq('#cffafe')
    end

    it 'ist idempotent (zweiter Lauf aendert nichts)' do
      add_org
      add_org
      user.reload.org_colors.ensure_defaults!
      before = user.reload.preferences['sidebar_colors']
      user.org_colors.ensure_defaults!
      expect(user.reload.preferences['sidebar_colors']).to eq(before)
    end

    # Pins the write guard (`unless updated == existing`): a no-change run
    # must stay a pure read. Rails' JSONB dirty check would suppress the
    # UPDATE anyway, but NOT the save round-trip — without the guard the
    # second run fires the users validation SELECTs (observable below).
    it 'macht den No-Change-Lauf als reine Leseoperation (kein Save-Roundtrip)' do
      add_org
      add_org
      user.reload.org_colors.ensure_defaults! # first run assigns (or the hook already did)

      queries = []
      counter = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
      end
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        user.org_colors.ensure_defaults!
      end

      # Format-independent: ONLY the memberships pluck may fire. Pinning the
      # allowed query instead of grepping for users-SELECT shapes keeps the
      # guard loud if Devise/validations ever change their SQL format.
      expect(queries.grep_v(/FROM "memberships"/)).to be_empty
      expect(queries.grep(/INSERT|UPDATE|DELETE/i)).to be_empty
    end

    it 'zaehlt nur AKTIVE Orgs: 1 aktiv + 1 inaktiv -> kein Auto-Faerben' do
      # Kills memberships.active -> memberships in the ensure_ path.
      org = add_org(active: true)
      add_org(active: false)
      user.reload.org_colors.ensure_defaults!
      expect(user.reload.org_colors.setting_for(org)).to be_nil
    end

    it 'faerbt eine spaeter dazukommende 3. Org distinkt (inkrementell, ohne Kollision)' do
      a = add_org
      b = add_org
      c = add_org # hook colors incrementally
      user.reload
      colors = [a, b, c].map { |o| user.org_colors.setting_for(o) }
      expect(colors).to all(satisfy { |v| OrgColor.hex?(v) })
      expect(colors.uniq.size).to eq(3) # all three distinct
    end
  end

  describe 'Membership-Hook (Auto-Zuweisung bei der 2. Org)' do
    it 'faerbt KEINE Org bei nur einer Mitgliedschaft' do
      org = add_org
      expect(user.reload.org_colors.setting_for(org)).to be_nil
    end

    it 'faerbt die Orgs automatisch, sobald die 2. aktive Org dazukommt' do
      a = add_org
      b = add_org # hook fires here
      expect(OrgColor.hex?(user.reload.org_colors.setting_for(a))).to be(true)
      expect(OrgColor.hex?(user.org_colors.setting_for(b))).to be(true)
    end

    it 'faerbt NICHT, wenn die 2. Mitgliedschaft inaktiv ist' do
      # End-to-end: the hook does fire, but the active org count stays 1 -> no coloring.
      a = add_org(active: true)
      add_org(active: false)
      expect(user.reload.org_colors.setting_for(a)).to be_nil
    end

    it 'faerbt nach, wenn eine inaktive 2. Org spaeter REAKTIVIERT wird (update-Hook)' do
      # Closes the gap: without after_update_commit the user would have 2 active orgs, but
      # never any colors (the create hook only fired on the inactive creation with count 1).
      a = add_org(active: true)
      add_org(active: false)
      expect(user.reload.org_colors.setting_for(a)).to be_nil # precondition: still uncolored
      user.memberships.where.not(organisation: a).first.update!(active: true) # reactivation
      expect(OrgColor.hex?(user.reload.org_colors.setting_for(a))).to be(true)
    end
  end

  describe 'Zusammenhaengende Ablaeufe (PORO <-> User <-> Hook)' do
    it 'Voll-Kette: Hook weist zu -> effective_color liefert genau diese Farbe' do
      a = add_org
      add_org
      user.reload
      expect(user.org_colors.effective_color(a)).to be_present
      expect(user.org_colors.effective_color(a)).to eq(user.org_colors.setting_for(a))
    end

    it 'Faellt der User unter 2 aktive Orgs, verschwindet das Signal — die Farbe bleibt gespeichert' do
      a = add_org
      add_org
      user.reload
      auto = user.org_colors.setting_for(a)
      expect(OrgColor.hex?(auto)).to be(true)
      user.memberships.where.not(organisation: a).first.update!(active: false)
      expect(user.org_colors.effective_color(a)).to be_nil # gate: only 1 active org left
      expect(user.org_colors.setting_for(a)).to eq(auto) # stored color survives
    end

    it 'ist pro User isoliert: Bs Aenderung ueberschreibt NICHT die gespeicherte Farbe von A' do
      other = create(:user)
      org = add_org
      user.org_colors.set(org, '#cffafe')
      other.org_colors.set(org, '#ffedd5') # different row, own user
      expect(user.reload.org_colors.setting_for(org)).to eq('#cffafe') # not clobbered by B's save
      expect(other.org_colors.setting_for(org)).to eq('#ffedd5')
    end

    # Sibling-slot coexistence (twin of the sidebar_pins audit): every write
    # path must go through preference_store (merge + full reassignment). A
    # mutant writing `user.preferences = { PREF_KEY => colors }` directly
    # would wipe unrelated preference slots — pinned here for BOTH writers.
    it '#set laesst fremde preference-Slots unangetastet' do
      org = add_org
      user.preference_store.set('items_per_page', 50)
      user.org_colors.set(org, '#dbeafe')
      user.org_colors.set(org, :auto) # delete path also writes
      expect(user.reload.preferences['items_per_page']).to eq(50)
    end

    it '#ensure_defaults! laesst fremde preference-Slots unangetastet' do
      add_org
      add_org
      user.reload.preference_store.set('items_per_page', 50)
      user.org_colors.set(user.memberships.active.first.organisation_id, :auto) # one org back to auto
      user.org_colors.ensure_defaults! # reassigns -> real write run
      expect(user.reload.preferences['items_per_page']).to eq(50)
    end

    it 'durchlaeuft den 3-Zustand als Sequenz: Farbe -> aus -> automatisch (effective folgt)' do
      a = add_org
      add_org
      user.reload # consistent instance after the hook writes
      user.org_colors.set(a, '#cffafe')
      expect(user.org_colors.effective_color(a)).to eq('#cffafe')             # own color
      user.org_colors.set(a, OrgColor::OFF)
      expect(user.org_colors.effective_color(a)).to be_nil                    # deliberately off
      user.org_colors.set(a, :auto)
      expect(user.org_colors.effective_color(a)).to be_nil                    # "automatic" shows nothing yet WITHOUT ensure_
      user.org_colors.ensure_defaults!
      expect(OrgColor.hex?(user.org_colors.effective_color(a))).to be(true)   # only ensure_ assigns the auto color
    end

    it 'effective_color fuer viele Orgs erzeugt KEIN COUNT-N+1 (memoisiert)' do
      a = add_org
      b = add_org
      c = add_org
      orgs = [a, b, c]
      user.reload
      # Loop = same call site: without the org_count memo in the PORO this would be a
      # COUNT N+1 (Prosopite guard would go red). With the memo, only ONE COUNT.
      results = orgs.map { |o| user.org_colors.effective_color(o) }
      expect(results).to all(be_present)
    end
  end

  describe 'query-count guard (org count memo)' do
    # Invariant from the split plan (user split, slice 3): resolving the
    # effective color for EVERY org of a user (org selection banderole,
    # <html> brand variable) must fire exactly ONE memberships COUNT query —
    # the count is memoized per instance. Without the memo this becomes a
    # silent COUNT N+1 on every page. Green against the pre-extraction code
    # (proves: one query today) and the safety net after the extraction.
    it 'fires exactly one memberships COUNT query when resolving 3 orgs' do
      # Separate lines on purpose: Prosopite fingerprints by call site, a
      # single-line `[add_org, add_org, add_org]` reads as a setup N+1.
      a = add_org
      b = add_org
      c = add_org
      orgs = [a, b, c]
      fresh = User.find(user.id) # fresh instance => memo guaranteed empty

      queries = []
      counter = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
      end

      results = nil
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        results = orgs.map { |o| fresh.org_colors.effective_color(o) }
      end

      count_queries = queries.grep(/SELECT COUNT/i).grep(/memberships/i)
      expect(count_queries.size).to eq(1)
      expect(results).to all(be_present) # the memoized count actually fed the gate
    end

    # Zero boundary for the memo contract from the code comment ("0 is truthy
    # in Ruby, so ||= is also correct for no orgs"): a user with NO active
    # orgs is productively reachable (all memberships deactivated, layout
    # still renders effective_color). The memoized 0 must short-circuit the
    # second call — kills idiom drift like `count.nonzero?` (would re-query
    # AND crash the gate with nil) and falsy-aware memo rewrites.
    it 'memoizes a zero org count (no re-query, gate yields nil)' do
      foreign_org = create(:organisation) # no membership for `user`
      fresh = User.find(user.id)

      queries = []
      counter = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
      end

      results = nil
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        results = [fresh.org_colors.effective_color(foreign_org),
                   fresh.org_colors.effective_color(foreign_org)]
      end

      expect(results).to eq([nil, nil]) # gate closed at 0 orgs
      expect(queries.grep(/SELECT COUNT/i).grep(/memberships/i).size).to eq(1)
    end
  end

  describe '.backfill_all! (Bestands-User)' do
    # Simulates pre-feature existing data: user with >=2 orgs, but EMPTIED colors (otherwise
    # the create hook would already have colored them). Prosopite is deliberately paused here: the
    # backfill is a one-off batch run (not a request) and intentionally makes per-user queries.
    def existing_multi_org_user_without_colors
      u = create(:user)
      add_org(u)
      add_org(u)
      u.update!(preferences: u.preferences.merge('sidebar_colors' => {}))
      u
    end

    it 'faerbt Bestands-Multi-Org-User nach und zaehlt nur die geaenderten' do
      Prosopite.pause
      begin
        u1 = existing_multi_org_user_without_colors
        existing_multi_org_user_without_colors
        single = create(:user)
        add_org(single) # only 1 org -> stays untouched

        expect(described_class.backfill_all!).to eq(2)

        expect(u1.reload.preferences['sidebar_colors'].values).to all(satisfy { |v| OrgColor.hex?(v) })
        expect(single.reload.preferences['sidebar_colors']).to be_blank
      ensure
        Prosopite.resume
      end
    end

    it 'ist idempotent (zweiter Lauf aendert 0)' do
      Prosopite.pause
      begin
        existing_multi_org_user_without_colors
        described_class.backfill_all!                  # 1st run colors
        expect(described_class.backfill_all!).to eq(0) # 2nd run: nothing left to do
      ensure
        Prosopite.resume
      end
    end

    it 'ueberschreibt eine bewusste OFF-Wahl NICHT (Migrations-Invariante)' do
      Prosopite.pause
      begin
        u = create(:user)
        o1 = add_org(u)
        add_org(u)
        u.update!(preferences: u.preferences.merge('sidebar_colors' => { o1.id.to_s => OrgColor::OFF }))
        described_class.backfill_all!
        expect(u.reload.org_colors.setting_for(o1)).to eq(OrgColor::OFF)
      ensure
        Prosopite.resume
      end
    end
  end
end
