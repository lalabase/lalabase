# frozen_string_literal: true

# One pending login hand-off from the main host to an organisation's host
# (doc/org_subdomains_plan.md, S3). Written and consumed only by Sessions::HostHandoff;
# it stores digests, never the token or the browser's state value.
class SessionHandoff < ApplicationRecord
  belongs_to :user
end
