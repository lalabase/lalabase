# frozen_string_literal: true

# == Schema Information
#
# Table name: view_states
#
#  id              :uuid             not null, primary key
#  key             :string           not null
#  state           :jsonb
#  viewable_type   :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  user_id         :uuid             not null
#  viewable_id     :uuid             not null
#
# Indexes
#
#  index_view_states_on_key              (key)
#  index_view_states_on_organisation_id  (organisation_id)
#  index_view_states_on_user_id          (user_id)
#  index_view_states_on_viewable         (viewable_type,viewable_id)
#  index_view_states_unique              (user_id,key,viewable_type,viewable_id,organisation_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

RSpec.describe ViewState, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:viewable) { organisation }

  before { ActsAsTenant.current_tenant = organisation }

  describe 'associations' do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:viewable) }
    it { is_expected.to belong_to(:organisation).without_validating_presence }
  end

  describe 'validations' do
    describe 'key' do
      it { is_expected.to validate_presence_of(:key) }

      it 'enforces uniqueness scoped to user, viewable, and organisation' do
        create(:view_state, user: user, key: 'sidebar', viewable: viewable, organisation: organisation)
        duplicate = build(:view_state, user: user, key: 'sidebar', viewable: viewable, organisation: organisation)

        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:key]).to be_present
      end

      it 'allows the same key for a different user' do
        other_user = create(:user)
        create(:view_state, user: user, key: 'sidebar', viewable: viewable, organisation: organisation)
        other = build(:view_state, user: other_user, key: 'sidebar', viewable: viewable, organisation: organisation)

        expect(other).to be_valid
      end

      it 'allows the same key for a different viewable' do
        project = create(:project, organisation: organisation)
        create(:view_state, user: user, key: 'sidebar', viewable: viewable, organisation: organisation)
        other = build(:view_state, user: user, key: 'sidebar', viewable: project, organisation: organisation)

        expect(other).to be_valid
      end
    end

    describe 'state' do
      it 'is valid with a hash' do
        view_state = build(:view_state, state: { 'key' => 'value' }, organisation: organisation)
        expect(view_state).to be_valid
      end

      it 'is valid with an empty hash' do
        view_state = build(:view_state, state: {}, organisation: organisation)
        expect(view_state).to be_valid
      end

      it 'is invalid when state is not a hash' do
        view_state = build(:view_state, organisation: organisation)
        view_state.state = 'not a hash'
        expect(view_state).not_to be_valid
        expect(view_state.errors[:state]).to be_present
      end

      it 'is invalid when state is an array' do
        view_state = build(:view_state, organisation: organisation)
        view_state.state = [1, 2, 3]
        expect(view_state).not_to be_valid
      end

      it 'is invalid when state is nil' do
        view_state = build(:view_state, organisation: organisation)
        view_state.state = nil
        expect(view_state).not_to be_valid
      end
    end
  end

  describe '#get_state' do
    subject(:view_state) do
      create(:view_state, :with_nested_state, user: user, viewable: viewable, organisation: organisation)
    end

    context 'with a top-level key' do
      it 'returns the value' do
        expect(view_state.get_state('accordion')).to eq({
                                                          'filter' => { 'expanded' => false, 'height' => '300px' }
                                                        })
      end
    end

    context 'with a nested dot-separated path' do
      it 'returns the deeply nested value' do
        expect(view_state.get_state('accordion.filter.expanded')).to eq(false)
      end

      it 'returns the intermediate hash' do
        expect(view_state.get_state('accordion.filter')).to eq({
                                                                 'expanded' => false, 'height' => '300px'
                                                               })
      end
    end

    context 'with a non-existent key' do
      it 'returns nil for a missing top-level key' do
        expect(view_state.get_state('nonexistent')).to be_nil
      end

      it 'returns nil for a missing nested key' do
        expect(view_state.get_state('accordion.filter.nonexistent')).to be_nil
      end

      it 'returns nil for a path beyond existing depth' do
        expect(view_state.get_state('accordion.filter.expanded.deeper')).to be_nil
      end
    end

    context 'with a path through a non-hash value' do
      before { view_state.update!(state: { 'name' => 'hello' }) }

      it 'returns nil instead of calling String#[]' do
        expect(view_state.get_state('name.sub')).to be_nil
      end
    end

    context 'with a blank path' do
      it 'returns the full state hash for an empty string' do
        expect(view_state.get_state('')).to eq(view_state.state)
      end

      it 'returns the full state hash for nil' do
        expect(view_state.get_state(nil)).to eq(view_state.state)
      end
    end

    context 'with an empty state hash' do
      before { view_state.update!(state: {}) }

      it 'returns nil for any path' do
        expect(view_state.get_state('anything')).to be_nil
      end
    end
  end

  describe '#set_state' do
    subject(:view_state) do
      create(:view_state, user: user, viewable: viewable, organisation: organisation, state: {})
    end

    context 'with a top-level key' do
      it 'sets the value and saves' do
        view_state.set_state('expanded', true)
        view_state.reload
        expect(view_state.state).to eq({ 'expanded' => true })
      end

      it 'returns true on successful save' do
        expect(view_state.set_state('expanded', true)).to be true
      end
    end

    context 'with a nested path' do
      it 'creates intermediate hashes and sets the value' do
        view_state.set_state('accordion.filter.expanded', false)
        view_state.reload
        expect(view_state.state).to eq({
                                         'accordion' => { 'filter' => { 'expanded' => false } }
                                       })
      end

      it 'creates deeply nested structures' do
        view_state.set_state('a.b.c.d.e', 'deep')
        view_state.reload
        expect(view_state.get_state('a.b.c.d.e')).to eq('deep')
      end
    end

    context 'overwriting existing values' do
      before { view_state.set_state('accordion.filter.expanded', false) }

      it 'overwrites a scalar value' do
        view_state.set_state('accordion.filter.expanded', true)
        view_state.reload
        expect(view_state.get_state('accordion.filter.expanded')).to eq(true)
      end

      it 'preserves sibling keys when setting a nested value' do
        view_state.set_state('accordion.filter.height', '300px')
        view_state.reload
        expect(view_state.get_state('accordion.filter.expanded')).to eq(false)
        expect(view_state.get_state('accordion.filter.height')).to eq('300px')
      end
    end

    context 'when an intermediate value is not a hash' do
      before { view_state.set_state('path', 'scalar_value') }

      it 'replaces the non-hash value with a hash to create the path' do
        view_state.set_state('path.nested', 'new_value')
        view_state.reload
        expect(view_state.get_state('path.nested')).to eq('new_value')
        expect(view_state.get_state('path')).to eq({ 'nested' => 'new_value' })
      end
    end

    context 'with a blank path' do
      it 'raises ArgumentError for an empty string' do
        expect { view_state.set_state('', 'value') }.to raise_error(ArgumentError, /path must be present/)
      end

      it 'raises ArgumentError for nil' do
        expect { view_state.set_state(nil, 'value') }.to raise_error(ArgumentError, /path must be present/)
      end
    end

    context 'when state is nil in memory' do
      it 'initializes state to empty hash before setting' do
        view_state.state = nil
        # Bypass validation to test the nil-guard in set_state
        view_state.save!(validate: false)
        view_state.reload

        # state comes back as nil from DB if set via validate: false,
        # but the DB default is {}, so reload should give {}
        view_state.set_state('key', 'value')
        view_state.reload
        expect(view_state.get_state('key')).to eq('value')
      end
    end

    context 'when save fails due to validation' do
      it 'returns false' do
        view_state.key = nil # triggers presence validation failure
        result = view_state.set_state('foo', 'bar')
        expect(result).to be false
      end

      it 'mutates the in-memory state even though save failed' do
        view_state.key = nil
        view_state.set_state('foo', 'bar')
        expect(view_state.state['foo']).to eq('bar')
      end
    end

    context 'with various value types' do
      it 'stores string values' do
        view_state.set_state('str', 'hello')
        view_state.reload
        expect(view_state.get_state('str')).to eq('hello')
      end

      it 'stores numeric values' do
        view_state.set_state('num', 42)
        view_state.reload
        expect(view_state.get_state('num')).to eq(42)
      end

      it 'stores boolean values' do
        view_state.set_state('bool', false)
        view_state.reload
        expect(view_state.get_state('bool')).to eq(false)
      end

      it 'stores nil values' do
        view_state.set_state('nullable', nil)
        view_state.reload
        expect(view_state.state).to have_key('nullable')
        expect(view_state.get_state('nullable')).to be_nil
      end

      it 'stores hash values' do
        view_state.set_state('nested', { 'a' => 1 })
        view_state.reload
        expect(view_state.get_state('nested')).to eq({ 'a' => 1 })
      end
    end
  end

  describe '.for_user_and_viewable' do
    context 'when no record exists' do
      it 'creates a new record' do
        expect do
          described_class.for_user_and_viewable(user, 'sidebar', viewable)
        end.to change(described_class, :count).by(1)
      end

      it 'returns a persisted record with correct attributes' do
        result = described_class.for_user_and_viewable(user, 'sidebar', viewable)
        expect(result).to be_persisted
        expect(result.user).to eq(user)
        expect(result.key).to eq('sidebar')
        expect(result.viewable).to eq(viewable)
        expect(result.organisation).to eq(organisation)
      end
    end

    context 'when a record already exists' do
      let!(:existing) do
        create(:view_state, user: user, key: 'sidebar', viewable: viewable,
                            organisation: organisation, state: { 'expanded' => true })
      end

      it 'returns the existing record' do
        result = described_class.for_user_and_viewable(user, 'sidebar', viewable)
        expect(result).to eq(existing)
      end

      it 'does not create a new record' do
        expect do
          described_class.for_user_and_viewable(user, 'sidebar', viewable)
        end.not_to change(described_class, :count)
      end

      it 'preserves the existing state' do
        result = described_class.for_user_and_viewable(user, 'sidebar', viewable)
        expect(result.state).to eq({ 'expanded' => true })
      end
    end

    context 'race condition — RecordNotUnique from unique index' do
      it 'falls back to find_by! when a concurrent insert hits the unique index' do
        existing = create(:view_state, user: user, key: 'sidebar', viewable: viewable, organisation: organisation)

        # Simulate race: first call to find_or_create_by raises RecordNotUnique
        call_count = 0
        allow(described_class).to receive(:find_or_create_by).and_wrap_original do |method, **args|
          call_count += 1
          raise ActiveRecord::RecordNotUnique.new('PG::UniqueViolation') if call_count == 1

          method.call(**args)
        end

        result = described_class.for_user_and_viewable(user, 'sidebar', viewable)
        expect(result).to eq(existing)
      end
    end

    context 'when tenant is not set' do
      before { ActsAsTenant.current_tenant = nil }

      it 'raises NoTenantSet from acts_as_tenant' do
        expect do
          described_class.for_user_and_viewable(user, 'sidebar', viewable)
        end.to raise_error(ActsAsTenant::Errors::NoTenantSet)
      end
    end
  end

  describe 'multi-tenancy' do
    let(:other_organisation) { create(:organisation) }

    it 'scopes records to the current tenant' do
      create(:view_state, user: user, key: 'sidebar', viewable: viewable, organisation: organisation)

      ActsAsTenant.with_tenant(other_organisation) do
        expect(described_class.count).to eq(0)
      end
    end

    it 'prevents accessing records from another tenant' do
      create(:view_state, user: user, key: 'sidebar', viewable: viewable, organisation: organisation)

      ActsAsTenant.with_tenant(other_organisation) do
        expect(described_class.find_by(user: user, key: 'sidebar')).to be_nil
      end
    end
  end

  describe 'factory' do
    it 'creates a valid view_state' do
      view_state = build(:view_state, organisation: organisation)
      expect(view_state).to be_valid
    end

    it 'creates a valid view_state with accordion state trait' do
      view_state = build(:view_state, :with_accordion_state, organisation: organisation)
      expect(view_state).to be_valid
      expect(view_state.state['expanded']).to eq(true)
    end

    it 'creates a valid view_state with nested state trait' do
      view_state = build(:view_state, :with_nested_state, organisation: organisation)
      expect(view_state).to be_valid
      expect(view_state.get_state('accordion.filter.expanded')).to eq(false)
    end
  end
end
