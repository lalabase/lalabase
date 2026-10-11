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
class ProjectRepository < ApplicationRecord
  PROVIDERS = %w[github gitlab].freeze
  # GitHub owner/repo: alphanumerics, dot, dash, underscore. Must not start with
  # a dot or dash. Both segments non-empty. Catches URL-injection vectors before
  # they hit the git binary (newlines, spaces, shell metachars, path traversal).
  FULL_NAME_PATTERN = %r{\A[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*\z}

  # Byte length for the per-repo webhook HMAC secret (hex-encoded → 64 chars).
  WEBHOOK_SECRET_BYTES = 32

  acts_as_tenant(:organisation)

  encrypts :access_token, deterministic: false
  encrypts :webhook_secret, deterministic: false

  # Maintenance rewrite path for the two encrypted columns above (backfill +
  # key rotation): rake encryption:reencrypt_tokens → .reencrypt_tokens!
  include TokenReencryptable
  reencrypts_tokens :access_token, :webhook_secret

  belongs_to :project
  belongs_to :connected_by_user, class_name: 'User', optional: true

  has_one  :project_index, dependent: :destroy
  has_many :code_symbols,  dependent: :destroy
  has_many :project_index_runs, dependent: :destroy
  has_many :documentation_sets, dependent: :destroy

  before_create :assign_webhook_secret
  after_create_commit :enqueue_indexing!

  def enqueue_indexing!
    ProjectIndex.create!(project_repository: self, organisation: organisation, status: 'pending') if project_index.nil?
    ProjectIndexerJob.perform_later(self)
  end

  # Per-repo HMAC secret for the inbound push webhook. Lazily backfills repos
  # connected before this feature existed (column is nullable). Idempotent.
  def ensure_webhook_secret!
    update!(webhook_secret: self.class.generate_webhook_secret) if webhook_secret.blank?
    webhook_secret
  end

  def self.generate_webhook_secret
    SecureRandom.hex(WEBHOOK_SECRET_BYTES)
  end

  # Public raw-content URL for one file in this repo (used e.g. to display
  # images referenced by synced documentation pages). Lives HERE, next to
  # `provider`, so host-specific URL knowledge has a single home: GitHub-only
  # for now — the same v1 limitation as Lalabase::Indexer::GitCloner. When
  # GitLab support lands, branch on `provider` in this one method.
  # NOTE: unauthenticated by design; files in private repos will 404 (accepted
  # v1 trade-off, see design OQ6 "images not guaranteed").
  def raw_file_url(path_in_repo)
    "https://raw.githubusercontent.com/#{full_name}/#{default_branch}/#{path_in_repo}"
  end

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :provider_repo_id, presence: true, uniqueness: { scope: %i[provider organisation_id] }
  validates :full_name, presence: true, format: { with: FULL_NAME_PATTERN, message: :invalid_full_name }
  validates :default_branch, presence: true
  validates :access_token, presence: true
  validates :connected_at, presence: true

  scope :for_project, ->(project) { where(project: project) }

  private

  # before_create twin of #ensure_webhook_secret! — SAME blank? condition (so an
  # explicit "" also gets a real secret, not just nil), but assigns in memory
  # since the create itself persists. They stay separate only because of WHEN
  # they save (callback vs. update! on an already-persisted row).
  def assign_webhook_secret
    self.webhook_secret = self.class.generate_webhook_secret if webhook_secret.blank?
  end
end
