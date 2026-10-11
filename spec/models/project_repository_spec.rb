# frozen_string_literal: true

# == Schema Information
#
# Table name: project_repositories
#
#  id                   :uuid             not null, primary key
#  access_token         :text             not null
#  connected_at         :datetime         not null
#  default_branch       :string           not null
#  full_name            :string           not null
#  provider             :string           not null
#  webhook_secret       :text
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  connected_by_user_id :uuid
#  organisation_id      :uuid             not null
#  project_id           :uuid             not null
#  provider_repo_id     :string           not null
#
# Indexes
#
#  idx_project_repositories_provider_repo_uniq         (provider,provider_repo_id,organisation_id) UNIQUE
#  index_project_repositories_on_connected_by_user_id  (connected_by_user_id)
#  index_project_repositories_on_organisation_id       (organisation_id)
#  index_project_repositories_on_project_id            (project_id)
#
# Foreign Keys
#
#  fk_rails_...  (connected_by_user_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#
require 'rails_helper'

RSpec.describe ProjectRepository, type: :model do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe 'validations' do
    subject { build(:project_repository) }

    it { is_expected.to be_valid }
    it { is_expected.to validate_presence_of(:provider) }
    it { is_expected.to validate_inclusion_of(:provider).in_array(described_class::PROVIDERS) }
    it { is_expected.to validate_presence_of(:provider_repo_id) }
    it { is_expected.to validate_presence_of(:full_name) }
    it { is_expected.to validate_presence_of(:default_branch) }
    it { is_expected.to validate_presence_of(:access_token) }
    it { is_expected.to validate_presence_of(:connected_at) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:connected_by_user).class_name('User').optional }
  end

  describe 'full_name format (defense against URL injection)' do
    %w[acme/backend a/b acme/repo-name acme/repo.name a/b_c.d 99designs/aws-vault].each do |good|
      it "accepts #{good.inspect}" do
        expect(build(:project_repository, full_name: good)).to be_valid
      end
    end

    ['acme/', '/repo', 'acme', 'acme/foo bar', 'acme/foo;rm', 'acme/foo.git@evil',
     '.acme/foo', '-acme/foo', 'acme/foo?', 'acme/foo#anchor'].each do |bad|
      it "rejects #{bad.inspect}" do
        expect(build(:project_repository, full_name: bad)).not_to be_valid
      end
    end

    it 'rejects newline-containing full_names (CR/LF injection)' do
      expect(build(:project_repository, full_name: "acme/foo\nrm -rf /")).not_to be_valid
    end

    it 'rejects path-traversal style values (..)' do
      expect(build(:project_repository, full_name: '../etc/passwd')).not_to be_valid
    end
  end

  describe 'multi-repo per project' do
    it 'allows multiple repositories for one project' do
      project = create(:project, organisation: organisation)
      repo_a = create(:project_repository, project: project, full_name: 'acme/backend')
      repo_b = create(:project_repository, project: project, full_name: 'acme/frontend')

      expect(project.reload.project_repositories).to contain_exactly(repo_a, repo_b)
    end
  end

  describe 'uniqueness within organisation' do
    it 'rejects a duplicate (provider, provider_repo_id) pair for the same org' do
      create(:project_repository, provider: 'github', provider_repo_id: 'repo-42')
      dupe = build(:project_repository, provider: 'github', provider_repo_id: 'repo-42')

      expect(dupe).not_to be_valid
      expect(dupe.errors[:provider_repo_id]).to be_present
    end
  end

  describe 'encryption' do
    it 'encrypts the access_token at rest' do
      repo = create(:project_repository, access_token: 'ghp_supersecret_value_42')

      raw = ActiveRecord::Base.connection.select_value(
        "SELECT access_token FROM project_repositories WHERE id = '#{repo.id}'"
      )
      expect(raw).not_to include('ghp_supersecret_value_42')
      expect(repo.reload.access_token).to eq('ghp_supersecret_value_42')
    end
  end

  # Rotation/backfill via TokenReencryptable. The concern's row semantics are
  # pinned HERE for all registered models (Admin::AiCredential keeps its own
  # legacy group for the delegating reencrypt_access_tokens! entry point):
  # every row must end up under the CURRENT primary key, without validations,
  # callbacks or updated_at noise, and one broken row must never abort the batch.
  describe '.reencrypt_tokens!' do
    # Reads straight from the column, bypassing the decrypting attribute type,
    # so assertions see what is ACTUALLY persisted (cleartext vs. envelope).
    def raw_column(id, column)
      conn = described_class.connection
      conn.select_value("SELECT #{column} FROM project_repositories WHERE id = #{conn.quote(id)}")
    end

    # Writes a raw value past the encrypting setters into ONE column. Since the
    # support_unencrypted_data cutoff there is no legitimate cleartext row
    # anymore — this helper only plants undecryptable ciphertext (foreign
    # envelopes) to exercise the failure paths.
    def store_raw(repo, column, value)
      conn = described_class.connection
      conn.execute(
        "UPDATE project_repositories SET #{column} = #{conn.quote(value)} WHERE id = #{conn.quote(repo.id)}"
      )
    end

    # An envelope under a key this app never had — decryptable by nobody.
    def foreign_envelope(value)
      foreign_provider = ActiveRecord::Encryption::KeyProvider.new(
        ActiveRecord::Encryption::Key.new(SecureRandom.random_bytes(32))
      )
      ActiveRecord::Encryption.encryptor.encrypt(value, key_provider: foreign_provider)
    end

    it 'rewrites both token columns through the attribute type (fresh envelope, value preserved)' do
      # Post-cutoff there is no cleartext backfill anymore — the sweep exists
      # for key ROTATION: every row is re-wrapped under the CURRENT primary
      # key. Observable as a changed envelope (fresh IV) around the same value.
      repo = create(:project_repository, access_token: 'ghp_rotate_me')
      token_raw_before = raw_column(repo.id, 'access_token')
      secret_raw_before = raw_column(repo.id, 'webhook_secret')

      expect(described_class.reencrypt_tokens!).to eq(processed: 1, failed: 0)

      expect(raw_column(repo.id, 'access_token')).not_to eq(token_raw_before)
      expect(raw_column(repo.id, 'webhook_secret')).not_to eq(secret_raw_before)
      repo = described_class.find(repo.id)
      expect(repo.access_token).to eq('ghp_rotate_me')
      expect(repo.webhook_secret).to be_present
    end

    it 'reaches rows of every organisation, not only the current tenant' do
      here = create(:project_repository)
      other_org = ActsAsTenant.without_tenant { create(:organisation) }
      elsewhere = ActsAsTenant.with_tenant(other_org) { create(:project_repository) }
      # Measurement probes, not app code: two same-shape raw SELECTs per phase
      # trip Prosopite's N+1 pattern — pause around the probe, never allowlist.
      raws_before = Prosopite.pause { [here, elsewhere].map { |r| raw_column(r.id, 'access_token') } }

      described_class.reencrypt_tokens!

      raws_after = Prosopite.pause { [here, elsewhere].map { |r| raw_column(r.id, 'access_token') } }
      expect(raws_after[0]).not_to eq(raws_before[0]) # re-wrapped
      expect(raws_after[1]).not_to eq(raws_before[1])
    end

    it 'is idempotent and does not bump updated_at (repair, not a domain change)' do
      repo = create(:project_repository)
      before = repo.reload.updated_at

      described_class.reencrypt_tokens!

      repo = described_class.find(repo.id)
      expect(repo.access_token).to be_present
      expect(repo.updated_at).to eq(before)
    end

    it 'skips an undecryptable value untouched, but still rewrites the healthy sister column' do
      # Since the support_unencrypted_data cutoff an undecryptable value RAISES
      # on read (pre-cutoff it came back as raw envelope and needed the
      # encrypted?-guard — that guard stays as defense-in-depth should the flag
      # ever return). Either way the contract is identical: never rewrite what
      # could not be decrypted, and isolate per COLUMN — the readable
      # webhook_secret must not die with its broken sister (after rotation
      # completes it would be unrecoverable).
      repo = create(:project_repository) # webhook_secret healthy (factory/callback)
      broken = foreign_envelope('ghp_lost_token')
      store_raw(repo, 'access_token', broken)
      secret_raw_before = raw_column(repo.id, 'webhook_secret')

      expect(described_class.reencrypt_tokens!).to eq(processed: 0, failed: 1) # surfaced, not reported as fixed

      expect(raw_column(repo.id, 'access_token')).to eq(broken) # untouched, not double-wrapped
      expect(raw_column(repo.id, 'webhook_secret')).not_to eq(secret_raw_before) # healthy column rewritten anyway
      expect(described_class.find(repo.id).webhook_secret).to be_present
    end

    it 'isolates a row that raises while processing and still encrypts the rest (per-row rescue)' do
      good = create(:project_repository, access_token: 'ghp_good_token')
      bad = instance_double(described_class, id: SecureRandom.uuid)
      allow(bad).to receive(:access_token).and_raise(ActiveRecord::Encryption::Errors::Decryption)
      allow(bad).to receive(:webhook_secret).and_raise(ActiveRecord::Encryption::Errors::Decryption)
      allow(bad).to receive(:update_columns) # never reached with both columns broken, stubbed defensively
      allow(described_class).to receive(:find_each).and_yield(good).and_yield(bad)

      expect(described_class.reencrypt_tokens!).to eq(processed: 1, failed: 1) # only the good row counts as processed

      expect(described_class.find(good.id).access_token).to eq('ghp_good_token')
    end

    it 'isolates a row whose WRITE fails and still encrypts the rest (outer per-row rescue)' do
      # The example above exercises the per-COLUMN rescue (readers raise); this
      # one forces the failure on the write side, which only the OUTER per-row
      # rescue catches. Without it, one DB-level hiccup (constraint, connection
      # blip) aborts the batch and leaves every later row under the retired
      # key — permanently unreadable once the rotation completes.
      failing = create(:project_repository, access_token: 'ghp_write_fails')
      healthy = create(:project_repository, access_token: 'ghp_write_works')
      allow_any_instance_of(described_class).to receive(:update_columns).and_wrap_original do |method, *args|
        raise ActiveRecord::StatementInvalid, 'simulated write failure' if method.receiver.id == failing.id

        method.call(*args)
      end

      expect(described_class.reencrypt_tokens!).to eq(processed: 1, failed: 1)

      expect(described_class.find(healthy.id).access_token).to eq('ghp_write_works')
    end
  end

  describe 'webhook secret' do
    it 'generates a 64-char hex secret on create' do
      repo = create(:project_repository)
      expect(repo.webhook_secret).to match(/\A[0-9a-f]{64}\z/)
    end

    it 'generates a distinct secret per repository' do
      a = create(:project_repository, full_name: 'acme/a')
      b = create(:project_repository, full_name: 'acme/b')
      expect(a.webhook_secret).not_to eq(b.webhook_secret)
    end

    it 'does not overwrite an explicitly provided secret' do
      repo = create(:project_repository, webhook_secret: 'preset-secret')
      expect(repo.reload.webhook_secret).to eq('preset-secret')
    end

    it 'encrypts the webhook_secret at rest' do
      repo = create(:project_repository, webhook_secret: 'whk_plaintext_value_99')
      raw = ActiveRecord::Base.connection.select_value(
        "SELECT webhook_secret FROM project_repositories WHERE id = '#{repo.id}'"
      )
      expect(raw).not_to include('whk_plaintext_value_99')
      expect(repo.reload.webhook_secret).to eq('whk_plaintext_value_99')
    end

    # Non-deterministic encryption is a security property: a deterministic scheme
    # would let two equal secrets be correlated by their ciphertext. This dies if
    # someone "harmonises" the column to `deterministic: true`.
    it 'uses NON-deterministic encryption — identical plaintext secrets get different ciphertext' do
      a = create(:project_repository, full_name: 'acme/a', webhook_secret: 'same-secret')
      b = create(:project_repository, full_name: 'acme/b', webhook_secret: 'same-secret')
      raw_a = ActiveRecord::Base.connection.select_value("SELECT webhook_secret FROM project_repositories WHERE id = '#{a.id}'")
      raw_b = ActiveRecord::Base.connection.select_value("SELECT webhook_secret FROM project_repositories WHERE id = '#{b.id}'")

      expect(raw_a).not_to eq(raw_b) # ciphertext differs (non-deterministic)
      expect(a.reload.webhook_secret).to eq('same-secret') # but both decrypt to the same plaintext
      expect(b.reload.webhook_secret).to eq('same-secret')
    end

    # Secret-byte length is a contract: shortening it weakens the HMAC. Locking
    # the constant + the generated form forces a deliberate change.
    it { expect(described_class::WEBHOOK_SECRET_BYTES).to eq(32) }

    it 'generate_webhook_secret returns 64 lowercase hex chars (2 × WEBHOOK_SECRET_BYTES)' do
      expect(described_class.generate_webhook_secret).to match(/\A[0-9a-f]{64}\z/)
    end

    describe '#ensure_webhook_secret!' do
      it 'backfills a secret when the column is blank (legacy repos connected pre-feature)' do
        repo = create(:project_repository)
        ActiveRecord::Base.connection.execute(
          "UPDATE project_repositories SET webhook_secret = NULL WHERE id = '#{repo.id}'"
        )
        repo.reload
        expect(repo.webhook_secret).to be_nil

        repo.ensure_webhook_secret!
        expect(repo.reload.webhook_secret).to match(/\A[0-9a-f]{64}\z/)
      end

      it 'is idempotent — keeps the existing secret' do
        repo = create(:project_repository)
        existing = repo.webhook_secret
        expect { repo.ensure_webhook_secret! }.not_to(change { repo.reload.webhook_secret })
        expect(repo.webhook_secret).to eq(existing)
      end
    end
  end

  describe 'tenant scoping' do
    it 'is scoped to the current tenant' do
      other_org = create(:organisation)
      mine = create(:project_repository)
      ActsAsTenant.with_tenant(other_org) do
        theirs = create(:project_repository)
        expect(described_class.all).to contain_exactly(theirs)
      end
      expect(described_class.all).to contain_exactly(mine)
    end

    it 'allows the same (provider, provider_repo_id) pair across different organisations' do
      create(:project_repository, provider: 'github', provider_repo_id: 'shared-repo-id')
      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        dupe_across_org = build(:project_repository, provider: 'github', provider_repo_id: 'shared-repo-id')
        expect(dupe_across_org).to be_valid
      end
    end
  end

  describe 'provider whitelist' do
    described_class::PROVIDERS.each do |allowed|
      it "accepts #{allowed.inspect}" do
        expect(build(:project_repository, provider: allowed)).to be_valid
      end
    end

    ['bitbucket', 'gitea', 'forgejo', 'GITHUB', 'github '].each do |bad|
      it "rejects #{bad.inspect}" do
        expect(build(:project_repository, provider: bad)).not_to be_valid
      end
    end
  end

  describe 'DB-level uniqueness (defense in depth)' do
    it 'raises RecordNotUnique when model validation is bypassed' do
      first = create(:project_repository, provider: 'github', provider_repo_id: 'r-race-1')
      racer = build(:project_repository, provider: 'github', provider_repo_id: 'r-race-1',
                                         project: first.project)
      expect { racer.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows same provider_repo_id under a different provider' do
      create(:project_repository, provider: 'github', provider_repo_id: 'shared-42')
      sibling = build(:project_repository, provider: 'gitlab', provider_repo_id: 'shared-42')
      expect(sibling).to be_valid
    end
  end

  describe 'auto-indexing on create' do
    # The stub in spec/support/jobs_helper.rb prevents the job from actually running,
    # but the ProjectIndex creation in #enqueue_indexing! still runs.
    it 'creates a pending ProjectIndex when the repo is first persisted' do
      repo = build(:project_repository)
      expect { repo.save! }.to change(ProjectIndex, :count).by(1)
      expect(repo.project_index.status).to eq('pending')
    end

    it 'enqueues ProjectIndexerJob on after_create_commit' do
      expect(ProjectIndexerJob).to receive(:perform_later).with(an_instance_of(ProjectRepository))
      create(:project_repository)
    end

    it 'does NOT re-enqueue on update' do
      repo = create(:project_repository)
      expect(ProjectIndexerJob).not_to receive(:perform_later)
      repo.update!(full_name: 'acme/renamed')
    end
  end

  describe 'cascade on project destroy' do
    it 'is destroyed when its project is destroyed' do
      project = create(:project, organisation: organisation)
      repo = create(:project_repository, project: project)
      expect { project.destroy! }.to change(described_class, :count).by(-1)
      expect(described_class.where(id: repo.id)).to be_empty
    end
  end

  describe 'cascade to children on repository destroy' do
    # has_many :code_symbols, dependent: :destroy — without it, deleting a repo
    # would orphan its indexed symbols (or hit the FK). Catches a dropped dependent:.
    it 'destroys its code_symbols' do
      repo = create(:project_repository)
      create(:code_symbol, project_repository: repo, organisation: organisation,
                           qualified_name: 'Doomed', file_path: 'app/x.rb')
      expect { repo.destroy! }.to change(CodeSymbol, :count).by(-1)
    end

    # has_one :project_index, dependent: :destroy — the auto-created index must
    # go with the repo (no orphaned index rows).
    it 'destroys its project_index' do
      repo = create(:project_repository)
      expect(repo.project_index).to be_present
      expect { repo.destroy! }.to change(ProjectIndex, :count).by(-1)
    end
  end

  describe 'encryption with special characters' do
    it 'round-trips tokens containing slashes, plus, and underscores' do
      token = 'gho_AbCd+EfGh/IjKl_MnOp_1234567890==/test'
      repo = create(:project_repository, access_token: token)
      expect(repo.reload.access_token).to eq(token)
    end
  end

  describe '#raw_file_url' do
    it 'builds the raw content URL from full_name, default_branch and the given path' do
      repo = build(:project_repository, full_name: 'acme/docs', default_branch: 'develop')

      expect(repo.raw_file_url('docs/img/logo.png'))
        .to eq('https://raw.githubusercontent.com/acme/docs/develop/docs/img/logo.png')
    end

    it 'never embeds the access token (raw URLs are shipped to browsers)' do
      repo = build(:project_repository, access_token: 'ghp_secret_token')

      expect(repo.raw_file_url('a.png')).not_to include('ghp_secret_token')
    end
  end
end
