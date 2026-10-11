# frozen_string_literal: true

require 'rails_helper'

# S3c T3: the panel registry is the fail-closed door of the artefact lane
# (plan §8.1). The kind arrives in a client-settable address, so "unknown" is a
# case that happens in production, not a developer typo.
RSpec.describe Assistant::PanelRegistry do
  describe '.canonical_kind' do
    it 'answers the registry own spelling for a known kind' do
      expect(described_class.canonical_kind('report')).to eq('report')
    end

    # The controller renders a template named after THIS value. If it ever
    # returned the argument, `render` would take its target from the request.
    it 'returns the frozen key of the registry, not the argument object' do
      argument = +'report'

      expect(described_class.canonical_kind(argument)).not_to be_equal(argument)
    end

    it 'refuses everything unknown, including the kinds that are still to come' do
      %w[record results proposal Report ../secret].each do |unknown|
        expect(described_class.canonical_kind(unknown)).to be_nil
      end
    end

    it 'takes a symbol as well, since a caller may hand one over' do
      expect(described_class.canonical_kind(:report)).to eq('report')
    end

    it 'refuses nil and the empty string' do
      expect(described_class.canonical_kind(nil)).to be_nil
      expect(described_class.canonical_kind('')).to be_nil
    end
  end

  describe '.panel_for' do
    it 'resolves a known kind to its panel' do
      expect(described_class.panel_for('report')).to eq(Assistant::Panels::TimeReport)
    end

    it 'answers nil for an unknown kind' do
      expect(described_class.panel_for('proposal')).to be_nil
    end
  end

  # The contract every kind has to keep, checked over the WHOLE registry rather
  # than for the one kind that exists today: the next entry is a line in a hash,
  # and a line in a hash is exactly the kind of change nobody writes a spec for.
  describe 'the contract of every registered kind' do
    it 'has a panel that answers .call(user:, organisation:, params:) and #available?' do
      described_class.kinds.each do |kind|
        panel = described_class.panel_for(kind)

        expect(panel).to respond_to(:call)
        parameters = panel.method(:call).parameters
        expect(parameters).to include(%i[keyreq user], %i[keyreq organisation], %i[keyreq params])
        expect(panel.instance_methods).to include(:available?)
      end
    end

    it 'has a template of its own name under assistant_artefacts' do
      described_class.kinds.each do |kind|
        path = Rails.root.join("app/views/organisations/assistant_artefacts/#{kind}.html.erb")

        expect(path).to exist, "missing artefact template for kind #{kind}"
      end
    end

    # The other direction, which the first version missed: a template WITHOUT an
    # entry is a view nothing can reach -- or worse, a view somebody believes is
    # reachable. The pair has to match both ways, or the registry stops being the
    # list of what exists.
    it 'has no artefact template without a registry entry' do
      templates = Dir[Rails.root.join('app/views/organisations/assistant_artefacts/*.html.erb')]
                  .map { |path| File.basename(path, '.html.erb') }

      expect(templates - ['unavailable']).to match_array(described_class.kinds)
    end

    it 'keeps the registry frozen, so nothing registers a kind at runtime' do
      expect(described_class::PANELS).to be_frozen
    end

    it 'ships the refusal template every unknown kind falls back to' do
      expect(Rails.root.join('app/views/organisations/assistant_artefacts/unavailable.html.erb')).to exist
    end
  end
end
