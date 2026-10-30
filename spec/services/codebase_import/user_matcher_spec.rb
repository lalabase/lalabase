# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CodebaseImport::UserMatcher do
  let(:organisation) { create(:organisation) }
  let(:matcher) { described_class.new(organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe '#initialize' do
    it 'sets the organisation' do
      expect(matcher.instance_variable_get(:@organisation)).to eq(organisation)
    end
  end

  describe '#analyze' do
    let(:parsed_users) do
      [
        {
          id: '1',
          email: 'john@example.com',
          full_name: 'John Doe',
          role: { name: 'Developer', account_administrator: false }
        },
        {
          id: '2',
          email: 'admin@example.com',
          full_name: 'Admin User',
          role: { name: 'Administrator', account_administrator: true }
        }
      ]
    end

    it 'returns analysis for each user' do
      result = matcher.analyze(parsed_users)

      expect(result).to be_an(Array)
      expect(result.length).to eq(2)

      result.each do |user_analysis|
        expect(user_analysis).to have_key(:codebase_data)
        expect(user_analysis).to have_key(:existing_matches)
        expect(user_analysis).to have_key(:suggested_action)
        expect(user_analysis).to have_key(:suggested_role)
      end
    end

    it 'includes original codebase data' do
      result = matcher.analyze(parsed_users)

      expect(result.first[:codebase_data]).to eq(parsed_users.first)
      expect(result.second[:codebase_data]).to eq(parsed_users.second)
    end
  end

  describe '#find_potential_matches' do
    let(:matcher) { described_class.new(organisation) }
    let!(:existing_user) { create(:user, email: 'john@example.com', first_name: 'John', last_name: 'Doe') }
    let!(:membership) { create(:membership, user: existing_user, organisation: organisation, active: true) }

    context 'with exact email match' do
      let(:user_data) { { email: 'john@example.com', full_name: 'John Doe' } }

      it 'finds exact email matches with high confidence' do
        matches = matcher.send(:find_potential_matches, user_data)

        exact_match = matches.find { |m| m[:match_type] == :exact_email }
        expect(exact_match).to be_present
        expect(exact_match[:user]).to eq(existing_user)
        expect(exact_match[:confidence]).to eq(:high)
        expect(exact_match[:reason]).to eq('Identische E-Mail-Adresse')
      end
    end

    context 'with similar email domain' do
      let!(:domain_user) { create(:user, email: 'jane@example.com', first_name: 'Jane', last_name: 'Smith') }
      let!(:domain_membership) { create(:membership, user: domain_user, organisation: organisation, active: true) }
      let(:user_data) { { email: 'new@example.com', full_name: 'New User' } }

      it 'finds users with similar email domains' do
        matches = matcher.send(:find_potential_matches, user_data)

        similar_matches = matches.select { |m| m[:match_type] == :similar_email }
        expect(similar_matches.length).to be >= 1

        expect(similar_matches.map { |m| m[:user] }).to include(existing_user, domain_user)
        expect(similar_matches.first[:confidence]).to eq(:medium)
        expect(similar_matches.first[:reason]).to include('example.com')
      end

      # The domain of a hidden login address is not offered: the preview would
      # name the member next to it and so confirm where they sign in.
      it 'compares the email each member shows, never a hidden login address' do
        domain_user.update!(email_visibility: 'none')
        existing_user.update!(email_visibility: 'contact', contact_email: 'john.team@example.com')

        similar = matcher.send(:find_potential_matches, user_data).select { |m| m[:match_type] == :similar_email }

        expect(similar.map { |m| m[:user] }).to contain_exactly(existing_user)
      end
    end

    context 'with similar names' do
      let!(:name_user) { create(:user, email: 'different@domain.com', first_name: 'Johnny', last_name: 'Doe') }
      let!(:name_membership) { create(:membership, user: name_user, organisation: organisation, active: true) }
      let(:user_data) { { email: 'new@newdomain.com', full_name: 'John Doe' } }

      it 'finds users with similar names' do
        matches = matcher.send(:find_potential_matches, user_data)

        name_matches = matches.select { |m| m[:match_type] == :similar_name }
        expect(name_matches).to be_present

        expect(name_matches.map { |m| m[:user] }).to include(name_user)
        expect(name_matches.first[:confidence]).to eq(:low)
        expect(name_matches.first[:reason]).to include('Ähnlicher Name')
      end
    end

    context 'with no matches' do
      let(:user_data) { { email: 'nomatch@nowhere.com', full_name: 'No Match' } }

      it 'returns empty array when no matches found' do
        matches = matcher.send(:find_potential_matches, user_data)
        expect(matches).to eq([])
      end
    end

    context 'with inactive users' do
      let!(:inactive_user) { create(:user, email: 'inactive@example.com', first_name: 'Inactive', last_name: 'User', active: false) }
      let!(:inactive_membership) { create(:membership, user: inactive_user, organisation: organisation, active: false) }
      let(:user_data) { { email: 'test@example.com', full_name: 'Test User' } }

      it 'does not include inactive users in matches' do
        matches = matcher.send(:find_potential_matches, user_data)

        # The implementation uses @organisation.users.active which filters by User.active scope
        # Setting the user as inactive should prevent them from appearing in matches
        expect(matches.select { |m| m[:match_type] == :similar_email && m[:user] == inactive_user }).to be_empty
      end
    end

    it 'avoids duplicate matches' do
      # User that matches both email domain and name
      user_data = { email: 'test@example.com', full_name: 'John Doe' }

      matches = matcher.send(:find_potential_matches, user_data)
      user_ids = matches.map { |m| m[:user].id }

      expect(user_ids).to eq(user_ids.uniq) # No duplicates
    end
  end

  describe '#suggest_action' do
    let(:matcher) { described_class.new(organisation) }

    context 'with exact email match in organisation' do
      let!(:existing_user) { create(:user, email: 'john@example.com') }
      let!(:membership) { create(:membership, user: existing_user, organisation: organisation, active: true) }
      let(:user_data) { { email: 'john@example.com', full_name: 'John Doe' } }

      it 'suggests using existing user' do
        action = matcher.send(:suggest_action, user_data)
        expect(action).to eq(:use_existing)
      end
    end

    context 'with user existing globally but not in organisation' do
      let!(:global_user) { create(:user, email: 'global@example.com') }
      # User exists but no membership in current organisation
      let(:user_data) { { email: 'global@example.com', full_name: 'Global User' } }

      it 'suggests inviting to organisation' do
        action = matcher.send(:suggest_action, user_data)
        expect(action).to eq(:invite_to_organisation)
      end
    end

    context 'with completely new user' do
      let(:user_data) { { email: 'new@example.com', full_name: 'New User' } }

      it 'suggests creating new user' do
        action = matcher.send(:suggest_action, user_data)
        expect(action).to eq(:create_new)
      end
    end
  end

  describe '#suggest_role' do
    let(:matcher) { described_class.new(organisation) }
    let!(:admin_role) { create(:role, organisation: organisation, title: 'Admin', is_default: false) }
    let!(:default_role) { create(:role, organisation: organisation, title: 'User', is_default: true) }

    context 'with administrator user' do
      let(:user_data) do
        {
          role: { name: 'Developer', account_administrator: true }
        }
      end

      it 'suggests admin role for account administrators' do
        role_id = matcher.send(:suggest_role, user_data)
        expect(role_id).to eq(admin_role.id)
      end
    end

    context 'with role name containing admin' do
      let(:user_data) do
        {
          role: { name: 'Administrator', account_administrator: false }
        }
      end

      it 'suggests admin role for admin-named roles' do
        role_id = matcher.send(:suggest_role, user_data)
        expect(role_id).to eq(admin_role.id)
      end
    end

    context 'with regular user' do
      let(:user_data) do
        {
          role: { name: 'Developer', account_administrator: false }
        }
      end

      it 'suggests default role for regular users' do
        role_id = matcher.send(:suggest_role, user_data)
        expect(role_id).to eq(default_role.id)
      end
    end

    context 'when no admin role exists' do
      let(:user_data) do
        {
          role: { name: 'Administrator', account_administrator: true }
        }
      end

      before { admin_role.destroy }

      it 'falls back to default role' do
        role_id = matcher.send(:suggest_role, user_data)
        expect(role_id).to eq(default_role.id)
      end
    end

    context 'when no default role exists' do
      let(:user_data) do
        {
          role: { name: 'Developer', account_administrator: false }
        }
      end

      before { default_role.update!(is_default: false) }

      it 'falls back to first available role' do
        role_id = matcher.send(:suggest_role, user_data)
        expect(role_id).to be_present
        expect([admin_role.id, default_role.id]).to include(role_id)
      end
    end

    context 'when no roles exist at all' do
      let(:user_data) do
        {
          role: { name: 'Developer', account_administrator: false }
        }
      end

      before do
        admin_role.destroy
        default_role.destroy
      end

      it 'returns nil when no roles exist' do
        role_id = matcher.send(:suggest_role, user_data)
        expect(role_id).to be_nil
      end
    end
  end

  describe 'edge cases' do
    let(:matcher) { described_class.new(organisation) }

    context 'with malformed email' do
      let(:user_data) { { email: 'invalid-email', full_name: 'Test User' } }

      it 'handles malformed emails gracefully' do
        expect do
          matcher.send(:find_potential_matches, user_data)
        end.not_to raise_error
      end
    end

    context 'with empty name' do
      let(:user_data) { { email: 'test@example.com', full_name: '' } }

      it 'handles empty names gracefully' do
        matches = matcher.send(:find_potential_matches, user_data)
        expect(matches).to be_an(Array)
      end
    end

    context 'with nil values' do
      let(:user_data) { { email: nil, full_name: nil } }

      it 'handles nil values gracefully' do
        matches = matcher.send(:find_potential_matches, user_data)
        expect(matches).to eq([])
      end
    end

    context 'with very long names' do
      let(:long_name) { 'A' * 1000 }
      let(:user_data) { { email: 'test@example.com', full_name: long_name } }

      it 'handles very long names without errors' do
        expect do
          matcher.send(:find_potential_matches, user_data)
        end.not_to raise_error
      end
    end

    context 'with special characters in names' do
      let(:user_data) { { email: 'test@example.com', full_name: 'José María O\'Connor-Smith' } }

      it 'handles special characters in names' do
        expect do
          matcher.send(:find_potential_matches, user_data)
        end.not_to raise_error
      end
    end
  end
end
