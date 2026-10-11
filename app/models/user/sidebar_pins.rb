# frozen_string_literal: true

class User < ApplicationRecord
  # === Sidebar pins (user split, slice 2) ===
  # Pinned projects/menu sections per organisation, kept in
  # preferences['sidebar_pins']. Structure:
  #   { "<org_id>" => { "projects" => ["uuid", ...],
  #                     "sections" => { "<project_id>" => ["tickets", ...] } } }
  # projects order: most recently pinned first. Plain PORO holding a user
  # reference; it reads and writes exclusively through user.preference_store
  # (deep_dup + full reassignment => JSONB dirty tracking, never in-place
  # mutation of the stored hash). Mutating methods return the truthiness of
  # user.save. Access goes through User#sidebar_pins (memoized there => same
  # lifetime as the other per-instance caches).
  class SidebarPins
    # Slot inside users.preferences (JSONB) holding all pins.
    STORE_KEY = 'sidebar_pins'

    # Whitelist of pinnable menu sections.
    # 'chats' left this list with projekt_chat_abbau, 'time_sessions' with
    # doc/zeiten_eine_liste_plan.md (the project's own times page is gone; the
    # organisation list carries the project as a filter). Pins already stored
    # under those keys stay in the JSON and are inert -- the sidebar filters what
    # it renders through NAV_ITEMS, not through this list, so a section that no
    # longer exists simply never comes back.
    PINNABLE_SECTIONS = %w[tickets knowledge documentation meetings].freeze

    # Whitelist of pinnable org-level (non-project) items, stored under the 'global'
    # key of an org slot. Currently only the global search bar.
    GLOBAL_PINNABLE = %w[search].freeze

    def initialize(user)
      @user = user
    end

    # @return [Hash] { 'projects' => Array, 'sections' => Hash }
    def pins_for(organisation)
      raw = store.get(STORE_KEY, {})[store.org_key(organisation)] || {}
      { 'projects' => raw['projects'] || [], 'sections' => raw['sections'] || {} }
    end

    def project_pinned?(organisation, project_id)
      pins_for(organisation)['projects'].include?(project_id.to_s)
    end

    def pinned_sections_for(organisation, project_id)
      pins_for(organisation)['sections'][project_id.to_s] || []
    end

    def pin_project!(organisation, project_id)
      update_pins(organisation) do |pins|
        pid = project_id.to_s
        pins['projects'] = [pid] + (pins['projects'] - [pid])
      end
    end

    def unpin_project!(organisation, project_id)
      update_pins(organisation) do |pins|
        pid = project_id.to_s
        pins['projects'] -= [pid]
        pins['sections'].delete(pid)
      end
    end

    def pin_section!(organisation, project_id, section)
      return unless PINNABLE_SECTIONS.include?(section.to_s)

      update_pins(organisation) do |pins|
        pid = project_id.to_s
        pins['projects'] = [pid] + (pins['projects'] - [pid])
        sections = pins['sections'][pid] || []
        pins['sections'][pid] = sections | [section.to_s]
      end
    end

    def unpin_section!(organisation, project_id, section)
      update_pins(organisation) do |pins|
        pid = project_id.to_s
        remaining = (pins['sections'][pid] || []) - [section.to_s]
        if remaining.any?
          pins['sections'][pid] = remaining
        else
          pins['sections'].delete(pid)
        end
      end
    end

    # --- Org-level (non-project) pins, e.g. the global search bar. Stored under the
    # 'global' key so they never collide with project/section pins and leave the
    # pins_for contract ({ 'projects', 'sections' }) untouched. ---

    def global_pins_for(organisation)
      store.get(STORE_KEY, {}).dig(store.org_key(organisation), 'global') || []
    end

    def global_pinned?(organisation, key)
      global_pins_for(organisation).include?(key.to_s)
    end

    def pin_global!(organisation, key)
      return unless GLOBAL_PINNABLE.include?(key.to_s)

      update_pins(organisation) do |pins|
        pins['global'] = (pins['global'] || []) | [key.to_s]
      end
    end

    def unpin_global!(organisation, key)
      update_pins(organisation) do |pins|
        remaining = (pins['global'] || []) - [key.to_s]
        if remaining.any?
          pins['global'] = remaining
        else
          pins.delete('global')
        end
      end
    end

    private

    attr_reader :user

    def store
      user.preference_store
    end

    # Central mutation helper: yields the (deep-duped) pins of one org slot,
    # then writes the whole slot map back through the preference store. Empty
    # org slots (no projects, no sections) are removed entirely.
    def update_pins(organisation)
      org_id = store.org_key(organisation)
      all_pins = store.get(STORE_KEY, {}).deep_dup
      pins = all_pins[org_id] || { 'projects' => [], 'sections' => {} }
      pins['projects'] ||= []
      pins['sections'] ||= {}

      yield(pins)

      if pins['projects'].empty? && pins['sections'].empty? && (pins['global'] || []).empty?
        all_pins.delete(org_id)
      else
        all_pins[org_id] = pins
      end
      store.set(STORE_KEY, all_pins)
    end
  end
end
