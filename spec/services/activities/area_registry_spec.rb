# frozen_string_literal: true

require 'rails_helper'

# The activity gate's vocabulary (assistant plan §9a Befund 1, §13-11).
#
# The point of this spec is DRIFT: a new event type must fail here, while it is
# still somebody's pull request, rather than silently disappearing from the feed
# (fail-closed) or, worse, showing up ungated if a later change ever defaults.
RSpec.describe Activities::AreaRegistry do
  # Every key the application can emit, computed rather than listed:
  #   * Trackable auto-tracks created/updated/deleted on EVERY including model,
  #   * ProjectTrackable and TicketTrackable add their own actions,
  #   * AiProtocolActions writes the organisation.* events.
  # Activity#set_key composes "<trackable_type.underscore>.<action>".
  def emitted_keys
    Rails.application.eager_load!
    generic = ActiveRecord::Base.descendants.select { |m| m.include?(Trackable) }
                                .flat_map { |m| %w[created updated deleted].map { |a| "#{m.name.underscore}.#{a}" } }

    generic + actions_in('project_trackable').map { |a| "project.#{a}" } +
      actions_in('ticket_trackable').map { |a| "ticket.#{a}" } +
      AiProtocolActions::ALL.map { |a| "organisation.#{a}" }
  end

  def actions_in(concern)
    File.read(Rails.root.join("app/models/concerns/#{concern}.rb"))
        .scan(/action: '([a-z_]+)'/).flatten.uniq
  end

  describe 'coverage of everything the app emits' do
    it 'has a rule or an explicit exclusion for every emittable key' do
      unmapped = emitted_keys.reject do |key|
        described_class.area_for(key) || described_class.ignored?(key)
      end

      expect(unmapped).to be_empty,
                          "Unbekannte Aktivitäts-Schlüssel: #{unmapped.join(', ')}.\n" \
                          'Jeder gehört in AREA_BY_KEY oder unter IGNORED_PREFIXES.'
    end

    it 'maps no key that the app cannot emit (dead entries)' do
      expect(described_class::AREA_BY_KEY.keys - emitted_keys).to be_empty
    end
  end

  describe 'the gate itself' do
    # The reason this registry is keyed by `key` and not by trackable_type: on
    # `Project` rows the type says nothing about which area the event belongs to.
    it 'separates the events that share the Project trackable type' do
      expect(described_class.area_for('project.note_created')).to eq(:notes)
      expect(described_class.area_for('project.document_created')).to eq(:documents)
      expect(described_class.area_for('project.meeting_created')).to eq(:meetings)
      expect(described_class.area_for('project.meeting_moved_in')).to eq(:meetings)
      expect(described_class.area_for('project.meeting_moved_out')).to eq(:meetings)
      expect(described_class.area_for('project.member_added')).to eq(:members)
      expect(described_class.area_for('project.ticket_created')).to eq(:tickets)
    end

    it 'answers nil for an unknown key, so every caller drops the row' do
      expect(described_class.area_for('ticket.exploded')).to be_nil
      expect(described_class.area_for(nil)).to be_nil
      expect(described_class.area_for('')).to be_nil
    end

    it 'treats the non-project-bound families as ignored, not as gated' do
      %w[time_session_group.created organisation.ai_activated].each do |key|
        expect(described_class.ignored?(key)).to be(true)
        expect(described_class.area_for(key)).to be_nil
      end
    end

    it 'does not ignore anything that IS project-bound' do
      %w[ticket.created project.note_created].each do |key|
        expect(described_class.ignored?(key)).to be(false)
      end
    end

    # Every area a key points at has to be a real ProjectPermission column,
    # otherwise the reach lookup raises at runtime (the `:time_sessions` trap,
    # §2.4: accessible_project_ids has no such area).
    it 'uses only areas that ProjectPermission actually knows, plus PROJECT_LEVEL' do
      allowed = ProjectPermission.access_areas + [described_class::PROJECT_LEVEL]

      expect(described_class::AREA_BY_KEY.values.uniq - allowed).to be_empty
    end
  end

  describe '.keys_by_area' do
    it 'groups every mapped key under its area, losing none' do
      expect(described_class.keys_by_area.values.flatten).to match_array(described_class::AREA_BY_KEY.keys)
    end

    it 'is frozen, so nothing registers an area at runtime' do
      expect(described_class::AREA_BY_KEY).to be_frozen
      expect(described_class.keys_by_area).to be_frozen
    end
  end
end
