# frozen_string_literal: true

require 'rails_helper'

# Organisation.by_name is the one order for lists of organisations a person sees: the org
# switcher, its unread signal, the token inbox overview and the API lists. Ruby's sort and a
# plain ORDER BY name compare case-sensitively ("Zeta" before "alpha"); the switcher never did.
RSpec.describe Organisation, '.by_name' do
  it 'orders by name ignoring case, then by id' do
    zeta = create(:organisation, name: 'Zeta GmbH')
    alpha = create(:organisation, name: 'alpha GmbH')
    # Names are unique, so a tie on LOWER(name) needs two spellings of one name.
    twins = [create(:organisation, name: 'Mitte GmbH'), create(:organisation, name: 'MITTE GmbH')].sort_by(&:id)

    ids = [zeta, alpha, *twins].map(&:id)
    expect(described_class.where(id: ids).by_name.pluck(:id)).to eq([alpha.id, *twins.map(&:id), zeta.id])
  end

  it 'wins over an order already on the relation' do
    zeta = create(:organisation, name: 'Zeta GmbH')
    alpha = create(:organisation, name: 'alpha GmbH')

    expect(described_class.where(id: [zeta.id, alpha.id]).order(created_at: :desc).by_name.pluck(:id))
      .to eq([alpha.id, zeta.id])
  end
end
