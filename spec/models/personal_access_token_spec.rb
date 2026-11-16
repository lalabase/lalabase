# frozen_string_literal: true

# == Schema Information
#
# Table name: personal_access_tokens
#
#  id                :uuid             not null, primary key
#  all_organisations :boolean          default(FALSE), not null
#  expires_at        :datetime         not null
#  kind              :string           default("personal"), not null
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

  # A token is personal (made on the token page) or the token of a device (made by
  # the sign-in door). Every failure below has its success in the same block.
  describe 'kind' do
    include ActiveSupport::Testing::TimeHelpers

    def personal(**attrs)
      build(:personal_access_token, user: user, organisations: [organisation], **attrs)
    end

    def device(**attrs)
      build(:personal_access_token, :app_session, user: user, **attrs)
    end

    it 'is personal unless said otherwise, in the model and in the table' do
      expect(described_class.new.kind).to eq('personal')
      expect(personal.tap(&:save!).reload.kind).to eq('personal')
      expect(described_class.column_defaults['kind']).to eq('personal')
      expect(device.tap(&:save!).reload).to be_app_session
    end

    it 'knows two kinds, and the table refuses a third past the model' do
      expect(described_class::KINDS).to eq(%w[personal app_session])
      expect(personal(kind: 'robot')).not_to be_valid

      token = personal.tap(&:save!)
      expect { described_class.transaction(requires_new: true) { token.update_column(:kind, 'robot') } }
        .to raise_error(ActiveRecord::StatementInvalid, /personal_access_tokens_kind_known/)
      expect(token.reload.kind).to eq('personal')

      # The control: a known kind passes the same statement.
      expect { token.update_column(:kind, 'app_session') }.not_to raise_error
      expect(token.reload.kind).to eq('app_session')
    end

    describe 'the shape of a device token' do
      it 'reaches every organisation and may write' do
        expect(device).to be_valid
      end

      it 'is refused when it is limited to some organisations' do
        limited = build(:personal_access_token, user: user, organisations: [organisation],
                                                kind: 'app_session', read_only: false)

        expect(limited).not_to be_valid
        expect(limited.errors.details[:base]).to include(error: :app_session_shape)
        # The control: the same reach is fine for a personal token.
        expect(personal(read_only: false)).to be_valid
      end

      it 'is refused when it may only read' do
        reading = device(read_only: true)

        expect(reading).not_to be_valid
        expect(reading.errors.details[:base]).to include(error: :app_session_shape)
        # The control: a personal token for the whole account may be read-only.
        expect(build(:personal_access_token, :all_organisations, user: user, read_only: true)).to be_valid
      end

      it 'has a message in both languages' do
        %i[de en].each do |locale|
          message = I18n.with_locale(locale) { device(read_only: true).tap(&:valid?).errors.full_messages.first }
          expect(message).to be_present
          expect(message).not_to include('translation missing', 'Translation missing')
        end
      end
    end

    describe '#ends_at' do
      it 'is a year after a device token was made, and nil for a personal one' do
        freeze_time do
          expect(device.tap(&:save!).ends_at).to eq(described_class::APP_SESSION_MAX_AGE.from_now)
          expect(described_class::APP_SESSION_MAX_AGE).to eq(365.days)
          expect(personal.tap(&:save!).ends_at).to be_nil
        end
      end
    end

    # The expiry of a device token moves with its use: MAX_LIFETIME (90 days) after
    # the last use, never past a year after it was made. `at` plays a request: the
    # token is looked up the way every door does it and, when found, its use noted.
    describe 'the expiry of a device token' do
      let(:made_at) { Time.zone.local(2026, 1, 10, 12, 0, 0) }
      let!(:token) { travel_to(made_at) { device.tap(&:generate_token!) } }
      let(:plaintext) { token.token }

      def use_at(time)
        travel_to(time) { described_class.authenticate(plaintext)&.tap(&:record_use!) }
      end

      it 'starts 90 days after the sign-in' do
        expect(token.reload.expires_at).to eq(made_at + 90.days)
        expect(described_class::MAX_LIFETIME).to eq(90.days)
      end

      it 'works 89 days after the last use, and that use moves it another 90 days' do
        used = use_at(made_at + 89.days)

        expect(used).to eq(token)
        expect(token.reload.expires_at).to eq(made_at + 89.days + 90.days)
        expect(token.last_used_at).to eq(made_at + 89.days)
      end

      it 'is over exactly 90 days after the last use: the 90th day is outside' do
        expect(use_at(made_at + 90.days)).to be_nil
        expect(token.reload.expires_at).to eq(made_at + 90.days)
        # The control: a second before, it still works.
        expect(use_at(made_at + 90.days - 1.second)).to eq(token)
      end

      it 'is over 91 days after the last use' do
        expect(use_at(made_at + 91.days)).to be_nil
        # The control: the same token, used in time, lives on day 91.
        other = travel_to(made_at) { device.tap(&:generate_token!) }
        travel_to(made_at + 60.days) { described_class.authenticate(other.token).record_use! }
        expect(travel_to(made_at + 91.days) { described_class.authenticate(other.token) }).to eq(other)
      end

      context 'when it is used all year' do
        # Paused: the same lookup five times is the year passing, not an N+1.
        before { Prosopite.pause { [60, 120, 180, 240, 300].each { |day| use_at(made_at + day.days) } } }

        it 'never moves past a year after the sign-in' do
          expect(token.reload.expires_at).to eq(made_at + 365.days)
          expect(token.expires_at).to eq(token.ends_at)
        end

        it 'works on day 364, and that use moves nothing past the year' do
          expect(use_at(made_at + 364.days)).to eq(token)
          expect(token.reload.expires_at).to eq(made_at + 365.days)
        end

        it 'is over exactly 365 days after the sign-in: the 365th day is outside' do
          expect(use_at(made_at + 365.days)).to be_nil
          # The control: a second before, it still works.
          expect(use_at(made_at + 365.days - 1.second)).to eq(token)
        end

        it 'is over on day 366' do
          expect(use_at(made_at + 366.days)).to be_nil
          # The control: day 364 of the same token.
          expect(use_at(made_at + 364.days)).to eq(token)
        end
      end

      it 'never moves the expiry of a personal token' do
        mine = travel_to(made_at) { personal(expires_at: made_at + 30.days).tap(&:generate_token!) }

        travel_to(made_at + 10.days) { described_class.authenticate(mine.token).record_use! }

        expect(mine.reload.expires_at).to eq(made_at + 30.days)
        expect(mine.last_used_at).to eq(made_at + 10.days)
        # The control: the device token beside it moved.
        use_at(made_at + 10.days)
        expect(token.reload.expires_at).to eq(made_at + 100.days)
      end
    end

    describe '.make_room_for_app_session!' do
      let(:now) { Time.zone.local(2026, 3, 1, 12, 0, 0) }

      before { travel_to(now) }

      def device_used(days_ago, owner: user, **attrs)
        create(:personal_access_token, :app_session, user: owner, last_used_at: days_ago.days.ago, **attrs)
      end

      # One read for the whole list: a reload per token would be an N+1 of the spec.
      def revoked_among(tokens)
        described_class.where(id: tokens.map(&:id)).where.not(revoked_at: nil).to_a
      end

      it 'revokes nothing while a tenth device still fits' do
        devices = Array.new(9) { |i| device_used(i + 1) }

        expect(described_class.make_room_for_app_session!(user)).to be_empty
        expect(revoked_among(devices)).to be_empty
      end

      it 'revokes the device unused longest when an eleventh comes, and never a personal token' do
        oldest_personal = create(:personal_access_token, user: user, organisations: [organisation],
                                                         last_used_at: 80.days.ago)
        devices = Array.new(10) { |i| device_used(i + 1) }
        stalest = devices.last

        expect(described_class.make_room_for_app_session!(user)).to eq([stalest])

        expect(revoked_among(devices + [oldest_personal])).to eq([stalest])
        expect(described_class.active.app_sessions.where(user: user).count)
          .to eq(described_class::MAX_APP_SESSIONS - 1)
      end

      it 'counts a device never used from the day it was made' do
        devices = Array.new(9) { |i| device_used(i + 1) }
        never_used = create(:personal_access_token, :app_session, user: user, created_at: 30.days.ago)

        expect(described_class.make_room_for_app_session!(user)).to eq([never_used])
        expect(revoked_among(devices)).to be_empty
      end

      it 'counts live devices only, and only those of this account' do
        other_user = create(:user, organisation: organisation)
        theirs = Array.new(10) { |i| device_used(i + 1, owner: other_user) }
        mine = Array.new(9) { |i| device_used(i + 1) }
        device_used(50, revoked_at: 1.day.ago)
        create(:personal_access_token, :app_session, user: user, expires_at: 1.day.ago)

        expect(described_class.make_room_for_app_session!(user)).to be_empty
        expect(revoked_among(mine + theirs)).to be_empty
        # The control: one more live device of this account, and the stalest goes.
        device_used(1)
        expect(described_class.make_room_for_app_session!(user)).to eq([mine.last])
      end
    end
  end
end
