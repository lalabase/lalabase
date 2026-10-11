# frozen_string_literal: true

require 'rails_helper'

# What:  SmartFolderTicketsComponent item-count wiring.
# Why:   The limit reaches the SmartFolderService as `per_page: item_limit`. A full query test would
#        need a folder + service + matching tickets (disproportionate); the decision worth pinning is
#        that the `limit:` kwarg threads to the reader at all — a dropped `@limit = limit` in the
#        initializer would silently fix every smart-folder widget at the default. Tested on the private
#        reader (no service / DB needed).
RSpec.describe Dashboard::SmartFolderTicketsComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe '#item_limit (kwarg wiring)' do
    it 'defaults to 5 when no limit is given' do
      expect(described_class.new(project: project, user: user, smart_folder_id: nil).send(:item_limit)).to eq(5)
    end

    it 'uses a stored valid limit' do
      expect(described_class.new(project: project, user: user, smart_folder_id: nil, limit: 20).send(:item_limit)).to eq(20)
    end

    it 'ignores an out-of-whitelist limit and falls back to the default' do
      expect(described_class.new(project: project, user: user, smart_folder_id: nil, limit: 99).send(:item_limit)).to eq(5)
    end
  end
end
