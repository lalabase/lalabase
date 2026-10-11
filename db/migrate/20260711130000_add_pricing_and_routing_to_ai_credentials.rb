# frozen_string_literal: true

# S2 (KI-Kontingent): the AiCredential row becomes the single source of truth for
# BOTH how to reach a provider (api_base) AND what it costs (per-1M-token price
# fields), so the new Lalabase::Llm::CostCalculator can compute one authoritative
# cost instead of the two divergent 2024 price tables it replaces.
#
# Columns:
# * display_name       — human label for the effective provider name (attribution /
#                        Art. 13 transparency); falls back to `name`/`provider`.
# * purpose            — chat / embedding / both. Informational in S2; the routing
#                        that filters by it (EU chat vs US embedding) lands in S4.
# * region             — us / eu (nullable); sovereignty tagging for the S4 offering.
# * included_in_quota  — does usage on this credential count against the org quota
#                        (i.e. is it OUR metered system key)? Default FALSE so existing
#                        (un-priced) rows are not retroactively invalid under the price
#                        guard; an admin opts a credential into quota AND supplies its
#                        prices in one edit. BYOK is not a credential row.
# * api_base           — OpenAI-compatible base URL (supersedes the JSON
#                        additional_config['uri_base']; the model reads api_base
#                        first, uri_base as a back-compat fallback).
# * *_cost_per_1m_cents — integer cents per 1M tokens. Per-call cost is derived as
#                        (tokens / 1e6) * field and stored in the now-decimal
#                        ai_usages.cost_cents.
#
# All add_column only (nullable, or default on a boolean/string) — no table rewrite,
# no long lock. No data is backfilled here (project rule: data migrations run as a
# task/service); existing rows get the column defaults.
class AddPricingAndRoutingToAiCredentials < ActiveRecord::Migration[8.0]
  def change
    add_column :ai_credentials, :display_name, :string
    add_column :ai_credentials, :purpose, :string, default: 'both', null: false
    add_column :ai_credentials, :region, :string
    add_column :ai_credentials, :included_in_quota, :boolean, default: false, null: false
    add_column :ai_credentials, :api_base, :string
    add_column :ai_credentials, :input_cost_per_1m_cents, :integer
    add_column :ai_credentials, :output_cost_per_1m_cents, :integer
    add_column :ai_credentials, :embedding_cost_per_1m_cents, :integer
  end
end
