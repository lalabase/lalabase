# frozen_string_literal: true

# Durable idempotency record for an MCP write tool (D9). Keyed by (PAT, key): the
# first successful create_ticket/post_comment with a client-supplied key stores
# its response_content here; a repeat with the same key replays it instead of
# writing again. request_fingerprint pins the original parameters so reusing a key
# with a different payload is rejected rather than silently replayed.
#
# Not tenant-scoped: it belongs to a PersonalAccessToken (itself tenant-less), and
# the write it guards already runs inside the correct tenant.
# == Schema Information
#
# Table name: mcp_idempotency_keys
#
#  id                       :uuid             not null, primary key
#  idempotency_key          :string           not null
#  request_fingerprint      :string           not null
#  response_content         :text
#  tool_name                :string           not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  personal_access_token_id :uuid             not null
#
# Indexes
#
#  index_mcp_idempotency_keys_on_token_and_key  (personal_access_token_id,idempotency_key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (personal_access_token_id => personal_access_tokens.id)
#
class McpIdempotencyKey < ApplicationRecord
  belongs_to :personal_access_token

  validates :idempotency_key, presence: true, uniqueness: { scope: :personal_access_token_id }
  validates :tool_name, presence: true
  validates :request_fingerprint, presence: true
end
