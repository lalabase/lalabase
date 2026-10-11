# frozen_string_literal: true

require 'rails_helper'

# Specs for User::SidebarPins — pinned projects and menu sections per
# organisation, extracted from the User god-class (user.rb split, slice 2/7).
# Reached via user.sidebar_pins (no delegation facade; call sites use the PORO
# directly). Moved unchanged from spec/models/user_spec.rb plus added
# invariants, so these are CHARACTERIZATION tests: they pin the behaviour the
# legacy User methods already had, not new requirements.
#
# WHY THE EXAMPLES LOOK THE WAY THEY DO
#   - the section whitelist (PINNABLE_SECTIONS) is iterated over a HARDCODED
#     contract list, deliberately NOT over the constant: iterating the constant
#     would silently DROP an example when the whitelist shrinks instead of
#     failing (probe-verified);
#   - case / whitespace / blank variants stay rejected so a future
#     .downcase/.strip cannot silently widen the API;
#   - the "legacy/partial slot shapes" block feeds slots missing one of the two
#     keys (older writes, manual data): each example dies when one ||-default
#     guard is removed;
#   - pin ordering (most-recent-first, re-pin moves to front without
#     duplicating) and the empty-slot cleanup (the org slot disappears once
#     projects AND sections are both empty) are pinned because they are the
#     observable sidebar behaviour;
#   - mutating methods return user.save's truthiness and write through
#     preference_store (merge + full reassignment) so sibling slots survive.
RSpec.describe User::SidebarPins, type: :model do
  let(:user) { create(:user) }
  let(:pins) { user.sidebar_pins }
  let(:org) { create(:organisation) }
  let(:other_org) { create(:organisation) }
  let(:pid_a) { SecureRandom.uuid }
  let(:pid_b) { SecureRandom.uuid }

  describe 'memoization' do
    it 'returns the same instance for the same user instance' do
      expect(user.sidebar_pins).to equal(user.sidebar_pins)
    end
  end

  it 'pins and unpins a project scoped to the organisation' do
    pins.pin_project!(org, pid_a)

    expect(pins.project_pinned?(org, pid_a)).to be true
    expect(pins.project_pinned?(other_org, pid_a)).to be false

    pins.unpin_project!(org, pid_a)
    expect(pins.project_pinned?(org, pid_a)).to be false
  end

  it 'orders pinned projects most-recently-pinned first' do
    pins.pin_project!(org, pid_a)
    pins.pin_project!(org, pid_b)

    expect(pins.pins_for(org)['projects']).to eq([pid_b, pid_a])
  end

  it 're-pinning an existing project moves it to the front without duplicating' do
    pins.pin_project!(org, pid_a)
    pins.pin_project!(org, pid_b)
    pins.pin_project!(org, pid_a)

    expect(pins.pins_for(org)['projects']).to eq([pid_a, pid_b])
  end

  it 'pinning a section implies pinning the project' do
    pins.pin_section!(org, pid_a, 'tickets')

    expect(pins.project_pinned?(org, pid_a)).to be true
    expect(pins.pinned_sections_for(org, pid_a)).to eq(['tickets'])
  end

  it 'pinning a section moves the project to the front of the pinned projects' do
    pins.pin_project!(org, pid_a)
    pins.pin_project!(org, pid_b)

    pins.pin_section!(org, pid_a, 'tickets')

    expect(pins.pins_for(org)['projects']).to eq([pid_a, pid_b])
  end

  it 'pinning the same section twice keeps it once (set union)' do
    pins.pin_section!(org, pid_a, 'tickets')
    pins.pin_section!(org, pid_a, 'tickets')

    expect(pins.pinned_sections_for(org, pid_a)).to eq(['tickets'])
  end

  it 'rejects non-whitelisted sections' do
    pins.pin_section!(org, pid_a, 'settings')

    expect(pins.project_pinned?(org, pid_a)).to be false
    expect(pins.pinned_sections_for(org, pid_a)).to eq([])
  end

  describe 'section whitelist (PINNABLE_SECTIONS)' do
    # Positive iteration over the HARDCODED contract list, deliberately NOT
    # over the constant: iterating the constant would silently DROP the
    # example when the whitelist shrinks (probe-verified) instead of failing.
    %w[tickets knowledge documentation meetings].each do |section|
      it "accepts #{section.inspect} as pinnable" do
        pins.pin_section!(org, pid_a, section)

        expect(pins.pinned_sections_for(org, pid_a)).to eq([section])
      end
    end

    # Case, whitespace and blank stay rejected: include? must remain an exact
    # string match (a future .downcase/.strip would silently widen the API).
    ['Tickets', 'tickets ', ''].each do |bad|
      it "silently ignores #{bad.inspect}" do
        pins.pin_section!(org, pid_a, bad)

        expect(pins.project_pinned?(org, pid_a)).to be false
        expect(pins.pinned_sections_for(org, pid_a)).to eq([])
      end
    end

    # The project's own times page is gone (doc/zeiten_eine_liste_plan.md); a
    # pin stored under the old key stays inert in the JSON, like 'chats'.
    it 'rejects "time_sessions" now that there is no times tab to pin' do
      pins.pin_section!(org, pid_a, 'time_sessions')

      expect(pins.pinned_sections_for(org, pid_a)).to eq([])
    end

    it 'accepts a symbol section and stores it as string (to_s on check and storage)' do
      pins.pin_section!(org, pid_a, :tickets)

      expect(pins.pinned_sections_for(org, pid_a)).to eq(['tickets'])
    end
  end

  describe 'input normalization' do
    it 'normalizes non-string project ids on pin and query side' do
      pins.pin_project!(org, 123)

      expect(pins.pins_for(org)['projects']).to eq(['123'])
      expect(pins.project_pinned?(org, 123)).to be true
    end

    it 'normalizes the project id for section pins on pin and query side' do
      pins.pin_section!(org, 123, 'tickets')

      expect(pins.pins_for(org)['sections']).to have_key('123')
      expect(pins.pinned_sections_for(org, 123)).to eq(['tickets'])
    end
  end

  describe 'legacy/partial slot shapes' do
    # Stored slots are not guaranteed to carry both keys (older writes, manual
    # data). Readers default the missing half, the mutation helper guards both
    # keys before yielding — each of these dies when one ||-guard is removed.
    it 'defaults missing sections to {} when reading a projects-only slot' do
      user.update!(preferences: { 'sidebar_pins' => { org.id.to_s => { 'projects' => [pid_a] } } })

      expect(pins.pins_for(org)).to eq({ 'projects' => [pid_a], 'sections' => {} })
      expect(pins.pinned_sections_for(org, pid_a)).to eq([])
    end

    it 'defaults missing projects to [] when reading a sections-only slot' do
      user.update!(preferences: { 'sidebar_pins' => { org.id.to_s => { 'sections' => { pid_a => ['tickets'] } } } })

      expect(pins.pins_for(org)['projects']).to eq([])
      expect(pins.pinned_sections_for(org, pid_a)).to eq(['tickets'])
    end

    it 'mutates a projects-only slot without crashing or losing data' do
      user.update!(preferences: { 'sidebar_pins' => { org.id.to_s => { 'projects' => [pid_b] } } })

      pins.pin_section!(org, pid_a, 'tickets')

      expect(pins.pins_for(org)['projects']).to eq([pid_a, pid_b])
      expect(pins.pinned_sections_for(org, pid_a)).to eq(['tickets'])
    end

    it 'mutates a sections-only slot without crashing or losing data' do
      user.update!(preferences: { 'sidebar_pins' => { org.id.to_s => { 'sections' => { pid_b => ['tickets'] } } } })

      pins.pin_project!(org, pid_a)

      expect(pins.pins_for(org)['projects']).to eq([pid_a])
      expect(pins.pinned_sections_for(org, pid_b)).to eq(['tickets'])
    end
  end

  describe 'unpin on never-pinned state (idempotent no-ops)' do
    it 'unpin_project! on an unpinned project is harmless and leaves no slot behind' do
      expect { pins.unpin_project!(org, pid_a) }.not_to raise_error

      expect(user.reload.preferences.fetch('sidebar_pins', {})).not_to have_key(org.id.to_s)
    end

    it 'unpin_section! for a project without sections is harmless and keeps the project pin' do
      pins.pin_project!(org, pid_a)

      expect { pins.unpin_section!(org, pid_a, 'tickets') }.not_to raise_error

      expect(pins.project_pinned?(org, pid_a)).to be true
    end
  end

  it 'unpinning one project leaves sibling pins and sections in the same org intact' do
    pins.pin_section!(org, pid_a, 'tickets')
    pins.pin_project!(org, pid_b)

    pins.unpin_project!(org, pid_b)

    expect(pins.pins_for(org)['projects']).to eq([pid_a])
    expect(pins.pinned_sections_for(org, pid_a)).to eq(['tickets'])
  end

  it 'coexists with other preference slots (merge semantics, no clobbering)' do
    pins.pin_section!(org, pid_a, 'tickets')
    user.preference_store.set_items_per_page(50)

    reloaded = User.find(user.id)
    expect(reloaded.preference_store.items_per_page_preference).to eq(50)
    expect(reloaded.sidebar_pins.pinned_sections_for(org, pid_a)).to eq(['tickets'])
  end

  it 'does not persist anything for a non-whitelisted section (silent no-op)' do
    expect do
      pins.pin_section!(org, pid_a, 'settings')
    end.not_to(change { user.reload.preferences })
  end

  # projekt_chat_abbau took 'chats' off PINNABLE_SECTIONS with the tab it pinned.
  # Turned into its opposite rather than deleted: a section that comes back into the
  # whitelist without a nav item to render would pin silently and show nothing.
  it 'refuses chats, whose tab is gone' do
    expect do
      pins.pin_section!(org, pid_a, 'chats')
    end.not_to(change { user.reload.preferences })
  end

  it 'accepts meetings (Gespräche) as a pinnable section' do
    pins.pin_section!(org, pid_a, 'meetings')

    expect(pins.pinned_sections_for(org, pid_a)).to eq(['meetings'])
  end

  it 'unpinning a project cascades to its sections' do
    pins.pin_section!(org, pid_a, 'tickets')
    pins.pin_section!(org, pid_a, 'knowledge')

    pins.unpin_project!(org, pid_a)

    expect(pins.pinned_sections_for(org, pid_a)).to eq([])
    expect(pins.project_pinned?(org, pid_a)).to be false
  end

  it 'keeps the project pinned when unpinning only one of several sections' do
    pins.pin_section!(org, pid_a, 'tickets')
    pins.pin_section!(org, pid_a, 'knowledge')

    pins.unpin_section!(org, pid_a, 'tickets')

    expect(pins.pinned_sections_for(org, pid_a)).to eq(['knowledge'])
    expect(pins.project_pinned?(org, pid_a)).to be true
  end

  it 'leaves the project pinned (without sections) after its last section is unpinned' do
    pins.pin_section!(org, pid_a, 'tickets')

    pins.unpin_section!(org, pid_a, 'tickets')

    expect(pins.pinned_sections_for(org, pid_a)).to eq([])
    expect(pins.project_pinned?(org, pid_a)).to be true
  end

  it 'drops the sections entry of a project after its last section is unpinned' do
    pins.pin_section!(org, pid_a, 'tickets')

    pins.unpin_section!(org, pid_a, 'tickets')

    expect(pins.pins_for(org)['sections']).not_to have_key(pid_a)
  end

  it 'removes the whole org slot once projects and sections are both empty' do
    pins.pin_project!(other_org, pid_b)
    pins.pin_project!(org, pid_a)

    pins.unpin_project!(org, pid_a)

    stored = user.reload.preferences.fetch('sidebar_pins', {})
    expect(stored).not_to have_key(org.id.to_s)
    expect(stored).to have_key(other_org.id.to_s)
  end

  it 'returns the default shape for an organisation without pins' do
    expect(pins.pins_for(org)).to eq({ 'projects' => [], 'sections' => {} })
  end

  it 'accepts an organisation id in place of the organisation object' do
    pins.pin_project!(org.id, pid_a)

    expect(pins.project_pinned?(org, pid_a)).to be true
    expect(pins.pins_for(org.id)['projects']).to eq([pid_a])
  end

  it 'returns the result of save from mutating methods' do
    expect(pins.pin_project!(org, pid_a)).to be true
    expect(pins.unpin_project!(org, pid_a)).to be true

    user.email = nil
    expect(pins.pin_project!(org, pid_b)).to be false
  end

  it 'persists pins across reload' do
    pins.pin_section!(org, pid_a, 'tickets')

    reloaded = User.find(user.id)
    expect(reloaded.sidebar_pins.pinned_sections_for(org, pid_a)).to eq(['tickets'])
  end

  it 'persists successive mutations on the same instance (no in-place mutation of stored state)' do
    pins.pin_project!(org, pid_a)
    pins.pin_project!(org, pid_b)

    reloaded = User.find(user.id)
    expect(reloaded.sidebar_pins.pins_for(org)['projects']).to eq([pid_b, pid_a])
  end

  # Org-level (non-project) pins, stored under the 'global' key — currently the
  # persistent search bar (Stage 2b). Mirrors the section-whitelist discipline and,
  # crucially, must NOT alter the pins_for contract that the rest of the suite pins.
  describe 'global (org-level) pins' do
    it 'pins and unpins the search bar scoped to the organisation' do
      pins.pin_global!(org, 'search')

      expect(pins.global_pinned?(org, 'search')).to be true
      expect(pins.global_pinned?(other_org, 'search')).to be false

      pins.unpin_global!(org, 'search')
      expect(pins.global_pinned?(org, 'search')).to be false
    end

    it 'leaves the pins_for contract shape untouched (projects/sections only)' do
      pins.pin_global!(org, 'search')

      expect(pins.pins_for(org)).to eq({ 'projects' => [], 'sections' => {} })
    end

    it 'pinning the same global key twice keeps it once (set union)' do
      pins.pin_global!(org, 'search')
      pins.pin_global!(org, 'search')

      expect(pins.global_pins_for(org)).to eq(['search'])
    end

    # Positive whitelist iteration over the HARDCODED contract list (not the constant),
    # so a shrinking whitelist fails loudly instead of silently dropping the example.
    %w[search].each do |key|
      it "accepts #{key.inspect} as a pinnable global item" do
        pins.pin_global!(org, key)

        expect(pins.global_pins_for(org)).to eq([key])
      end
    end

    # Case / whitespace / blank / unknown stay rejected: exact string match only.
    ['Search', 'search ', '', 'admin'].each do |bad|
      it "silently ignores the non-whitelisted global key #{bad.inspect}" do
        pins.pin_global!(org, bad)

        expect(pins.global_pins_for(org)).to eq([])
      end
    end

    it 'accepts a symbol global key and stores it as a string' do
      pins.pin_global!(org, :search)

      expect(pins.global_pins_for(org)).to eq(['search'])
    end

    it 'coexists with project and section pins in the same org slot' do
      pins.pin_section!(org, pid_a, 'tickets')
      pins.pin_global!(org, 'search')

      expect(pins.project_pinned?(org, pid_a)).to be true
      expect(pins.pinned_sections_for(org, pid_a)).to eq(['tickets'])
      expect(pins.global_pinned?(org, 'search')).to be true
    end

    it 'keeps the org slot alive while only the global pin remains' do
      pins.pin_project!(org, pid_a)
      pins.pin_global!(org, 'search')

      pins.unpin_project!(org, pid_a)

      expect(pins.global_pinned?(org, 'search')).to be true
      expect(user.reload.preferences.fetch('sidebar_pins', {})).to have_key(org.id.to_s)
    end

    it 'removes the org slot once projects, sections and global are all empty' do
      pins.pin_global!(org, 'search')

      pins.unpin_global!(org, 'search')

      expect(user.reload.preferences.fetch('sidebar_pins', {})).not_to have_key(org.id.to_s)
    end

    it 'reads [] for a legacy slot without a global key' do
      user.update!(preferences: { 'sidebar_pins' => { org.id.to_s => { 'projects' => [pid_a] } } })

      expect(pins.global_pins_for(org)).to eq([])
      expect(pins.global_pinned?(org, 'search')).to be false
    end

    it 'persists the global pin across reload' do
      pins.pin_global!(org, 'search')

      expect(User.find(user.id).sidebar_pins.global_pinned?(org, 'search')).to be true
    end

    it 'drops only the global key (not the whole slot) when other pins survive' do
      # The "all empty -> slot deleted" path masks a broken delete('global'): a surviving
      # project pin keeps the slot alive, so the delete must be observable here. A mutant
      # turning delete('global') into a no-op would leave the key and fail this.
      pins.pin_project!(org, pid_a)
      pins.pin_global!(org, 'search')

      pins.unpin_global!(org, 'search')

      expect(pins.global_pinned?(org, 'search')).to be false
      expect(pins.project_pinned?(org, pid_a)).to be true
      expect(user.reload.preferences['sidebar_pins'][org.id.to_s]).not_to have_key('global')
    end

    it 'does not persist anything for a non-whitelisted global key (silent no-op)' do
      # Mirrors the section-whitelist no-op test: a mutant dropping the GLOBAL_PINNABLE
      # guard in pin_global! would write 'admin' and change preferences -> caught here.
      expect { pins.pin_global!(org, 'admin') }.not_to(change { user.reload.preferences })
    end

    it 'treats unpinning a non-whitelisted global key as a harmless no-op' do
      # unpin_global! deliberately has NO whitelist guard (you must be able to remove a
      # key that was later delisted). Pin that intended asymmetry so it is not "fixed".
      expect { pins.unpin_global!(org, 'admin') }.not_to raise_error
      expect(user.reload.preferences.fetch('sidebar_pins', {})).not_to have_key(org.id.to_s)
    end

    it 'isolates the global pin per user (no leak to another user)' do
      other_user = create(:user)
      pins.pin_global!(org, 'search')

      expect(other_user.sidebar_pins.global_pinned?(org, 'search')).to be false
    end
  end
end
