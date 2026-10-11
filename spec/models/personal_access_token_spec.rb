# frozen_string_literal: true

# == Schema Information
#
# Table name: personal_access_tokens
#
#  id                :uuid             not null, primary key
#  all_organisations :boolean          default(FALSE), not null
#  expires_at        :datetime         not null
#  last_used_at      :datetime
#  name              :string           not null
#  read_only         :boolean          default(TRUE), not null
#  revoked_at        :datetime
#  token_hash        :string           not null
#  token_prefix      :string(12)       not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  user_id           :uuid             not null
#
# Indexes
#
#  index_personal_access_tokens_on_token_hash              (token_hash) UNIQUE
#  index_personal_access_tokens_on_user_id                 (user_id)
#  index_personal_access_tokens_on_user_id_and_created_at  (user_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

RSpec.describe PersonalAccessToken, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  describe 'associations' do
    it { should belong_to(:user) }
    it { should have_many(:personal_access_token_organisations).dependent(:destroy) }
    it { should have_many(:configured_organisations).through(:personal_access_token_organisations) }
    it { should have_many(:personal_access_token_projects).dependent(:destroy) }
    it { should have_many(:scoped_projects).through(:personal_access_token_projects) }
  end

  describe 'read_only (D3, MCP write gate)' do
    it 'defaults to read-only (least privilege) on a persisted token' do
      pat = create(:personal_access_token, user: user, organisations: [organisation])
      expect(pat.reload.read_only?).to be true
    end

    it 'can be created as writable when explicitly set' do
      pat = create(:personal_access_token, user: user, organisations: [organisation], read_only: false)
      expect(pat.reload.read_only?).to be false
    end
  end

  describe 'validations' do
    it 'requires a name' do
      pat = build(:personal_access_token, user: user, name: nil, organisations: [organisation])
      expect(pat).not_to be_valid
      expect(pat.errors[:name]).to be_present
    end

    it 'requires an expires_at' do
      pat = build(:personal_access_token, user: user, expires_at: nil, organisations: [organisation])
      expect(pat).not_to be_valid
      expect(pat.errors[:expires_at]).to be_present
    end

    it 'requires at least one organisation scope on create' do
      pat = build(:personal_access_token, user: user)
      pat.personal_access_token_organisations = []
      expect(pat).not_to be_valid
      expect(pat.errors[:base]).to include(I18n.t('activerecord.errors.models.personal_access_token.no_organisation_scope'))
    end

    it 'enforces uniqueness of token_hash' do
      pat_a = create(:personal_access_token, user: user, organisations: [organisation])
      pat_b = build(:personal_access_token, user: user, organisations: [organisation])
      pat_b.token_hash = pat_a.token_hash
      expect(pat_b).not_to be_valid
      expect(pat_b.errors[:token_hash]).to be_present
    end

    context 'with cross-org project scope' do
      let(:other_org) { create(:organisation) }
      let(:project_in_other_org) do
        ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
      end

      it 'rejects projects from organisations outside the token scope' do
        pat = build(:personal_access_token, user: user)
        pat.personal_access_token_organisations.build(organisation: organisation, all_projects: false)
        pat.personal_access_token_projects.build(project: project_in_other_org)

        expect(pat).not_to be_valid
        expect(pat.errors[:base]).to include(
          I18n.t('activerecord.errors.models.personal_access_token.project_outside_scoped_organisations')
        )
      end
    end
  end

  describe '#generate_token!' do
    let(:pat) do
      build(:personal_access_token, user: user, organisations: [organisation])
    end

    before do
      # Factory sets token fields preemptively; clear them so generate_token! does the work.
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.instance_variable_set(:@token, nil)
    end

    it 'creates a token with the expected prefix' do
      raw = pat.generate_token!
      expect(raw).to start_with(PersonalAccessToken::TOKEN_PREFIX)
      expect(raw.length).to eq(PersonalAccessToken::TOKEN_PREFIX.length + PersonalAccessToken::TOKEN_BODY_LENGTH)
    end

    it 'stores only the SHA256 hash, not the plaintext' do
      raw = pat.generate_token!
      expect(pat.token_hash).to eq(Digest::SHA256.hexdigest(raw))
      expect(PersonalAccessToken.pluck(:token_hash)).not_to include(raw)
    end

    it 'stores the displayable token prefix' do
      raw = pat.generate_token!
      expect(pat.token_prefix).to eq(raw.first(PersonalAccessToken::TOKEN_PREFIX_DISPLAY_LENGTH))
    end

    it 'exposes the plaintext only on the generating instance' do
      raw = pat.generate_token!
      reloaded = PersonalAccessToken.find(pat.id)
      expect(pat.token).to eq(raw)
      expect(reloaded.token).to be_nil
    end
  end

  describe '.authenticate' do
    let!(:pat) do
      pat = build(:personal_access_token, user: user, organisations: [organisation])
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
      pat
    end

    it 'returns the matching active token' do
      expect(PersonalAccessToken.authenticate(pat.token)).to eq(pat)
    end

    it 'returns nil for a blank string' do
      expect(PersonalAccessToken.authenticate('')).to be_nil
      expect(PersonalAccessToken.authenticate(nil)).to be_nil
    end

    it 'returns nil if the prefix is wrong' do
      expect(PersonalAccessToken.authenticate("ghp_#{pat.token.sub(PersonalAccessToken::TOKEN_PREFIX, '')}")).to be_nil
    end

    it 'returns nil for a revoked token' do
      pat.revoke!
      expect(PersonalAccessToken.authenticate(pat.token)).to be_nil
    end

    it 'returns nil for an expired token' do
      pat.update!(expires_at: 1.minute.ago)
      expect(PersonalAccessToken.authenticate(pat.token)).to be_nil
    end

    it 'returns nil for an unknown but well-formed token' do
      forged = "#{PersonalAccessToken::TOKEN_PREFIX}#{SecureRandom.alphanumeric(PersonalAccessToken::TOKEN_BODY_LENGTH)}"
      expect(PersonalAccessToken.authenticate(forged)).to be_nil
    end
  end

  describe '#revoke!' do
    let(:pat) { create(:personal_access_token, user: user, organisations: [organisation]) }

    it 'sets revoked_at and makes the token inactive' do
      expect { pat.revoke! }.to change { pat.reload.revoked? }.from(false).to(true)
      expect(pat).not_to be_active
    end
  end

  describe 'state predicates' do
    let(:pat) { create(:personal_access_token, user: user, organisations: [organisation]) }

    it '#active? is true for an unrevoked, non-expired token' do
      expect(pat).to be_active
    end

    it '#active? is false after revoke' do
      pat.revoke!
      expect(pat).not_to be_active
    end

    it '#expired? is true once expires_at has passed' do
      pat.update!(expires_at: 1.minute.ago)
      expect(pat).to be_expired
      expect(pat).not_to be_active
    end
  end

  describe '#accessible_organisation?' do
    let(:other_org) { create(:organisation) }
    let(:pat) { create(:personal_access_token, user: user, organisations: [organisation]) }

    it 'is true for an organisation in the scope' do
      expect(pat.accessible_organisation?(organisation)).to be true
    end

    it 'is false for an organisation not in the scope' do
      expect(pat.accessible_organisation?(other_org)).to be false
    end

    it 'is false for nil' do
      expect(pat.accessible_organisation?(nil)).to be false
    end
  end

  describe '#accessible_project?' do
    let(:project_a) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end
    let(:project_b) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end
    let(:other_org) { create(:organisation) }
    let(:project_in_other_org) do
      ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
    end

    context 'when org scope is all_projects=true' do
      let(:pat) { create(:personal_access_token, user: user, organisations: [organisation]) }

      it 'grants access to every project in that org' do
        expect(pat.accessible_project?(project_a)).to be true
        expect(pat.accessible_project?(project_b)).to be true
      end

      it 'denies projects of orgs outside the scope' do
        expect(pat.accessible_project?(project_in_other_org)).to be false
      end
    end

    context 'when org scope is all_projects=false' do
      let(:pat) do
        create(
          :personal_access_token,
          user: user,
          organisations: [organisation],
          project_scopes: { organisation => [project_a] }
        )
      end

      it 'grants access only to explicitly scoped projects' do
        expect(pat.accessible_project?(project_a)).to be true
      end

      it 'denies access to other projects in the same org' do
        expect(pat.accessible_project?(project_b)).to be false
      end
    end

    it 'denies access for a nil project' do
      pat = create(:personal_access_token, user: user, organisations: [organisation])
      expect(pat.accessible_project?(nil)).to be false
    end
  end

  describe 'cascade behavior' do
    let(:project) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end

    it 'destroys the organisation scope links when an organisation is destroyed' do
      create(:personal_access_token, user: user, organisations: [organisation])
      expect { organisation.destroy }
        .to change(PersonalAccessTokenOrganisation, :count).by(-1)
    end

    it 'destroys the project scope links when a project is destroyed' do
      create(
        :personal_access_token,
        user: user,
        organisations: [organisation],
        project_scopes: { organisation => [project] }
      )
      expect { project.destroy }
        .to change(PersonalAccessTokenProject, :count).by(-1)
    end

    it 'destroys all PAT scope links when the user is destroyed' do
      create(
        :personal_access_token,
        user: user,
        organisations: [organisation],
        project_scopes: { organisation => [project] }
      )
      expect { user.destroy }
        .to change(PersonalAccessToken, :count).by(-1)
        .and change(PersonalAccessTokenOrganisation, :count).by(-1)
        .and change(PersonalAccessTokenProject, :count).by(-1)
    end
  end

  describe '.active scope' do
    let!(:active_pat) { create(:personal_access_token, user: user, organisations: [organisation]) }
    let!(:revoked_pat) { create(:personal_access_token, :revoked, user: user, organisations: [organisation]) }
    let!(:expired_pat) { create(:personal_access_token, :expired, user: user, organisations: [organisation]) }

    it 'returns only active tokens' do
      expect(PersonalAccessToken.active).to contain_exactly(active_pat)
    end
  end

  describe 'maximum lifetime' do
    include ActiveSupport::Testing::TimeHelpers

    around { |example| freeze_time { example.run } }

    def token_expiring_at(time)
      build(:personal_access_token, user: user, organisations: [organisation], expires_at: time)
    end

    it 'accepts a token expiring a day before the limit' do
      expect(token_expiring_at((described_class::MAX_LIFETIME - 1.day).from_now)).to be_valid
    end

    it 'accepts a token expiring exactly at the limit' do
      expect(token_expiring_at(described_class::MAX_LIFETIME.from_now)).to be_valid
    end

    it 'refuses a token expiring a second after the limit' do
      token = token_expiring_at(described_class::MAX_LIFETIME.from_now + 1.second)

      expect(token).not_to be_valid
      expect(token.errors[:expires_at]).to be_present
    end

    # Tokens created before the limit existed keep working until they expire.
    it 'does not refuse an update of an existing long-lived token' do
      token = token_expiring_at(1.year.from_now).tap { |t| t.save!(validate: false) }

      expect(token.update(name: 'Renamed')).to be(true)
    end
  end

  describe '.revoke_all_for!' do
    it 'revokes every live token of the user and nobody else\'s' do
      mine = create(:personal_access_token, user: user, organisations: [organisation])
      other_user = create(:user, organisation: organisation)
      theirs = create(:personal_access_token, user: other_user, organisations: [organisation])

      described_class.revoke_all_for!(user)

      expect(mine.reload).to be_revoked
      expect(theirs.reload).not_to be_revoked
    end
  end
end
