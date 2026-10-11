# frozen_string_literal: true

# KI-Pakete P2 / E12 (doc/ki_pakete_plan.md §3.3): the jurisdiction of a
# package derives from TWO independent facts per credential — where the
# provider company is seated and where the data is processed. The processing
# side already exists as ai_credentials.region ('eu'/'us'); this adds the
# company seat. With both stored, AiPackage#jurisdiction becomes a DERIVED,
# machine-checkable claim (matrix §3: ①–④ incl. the previously inexpressible
# ③ eu_provider_foreign_region) instead of relying on a hardcoded provider
# list that is structurally blind for openai_compatible (E12: a list that
# cannot answer the question is worse than a documented gap).
#
# Nullable, no backfill: NULL means "not recorded" and keeps today's
# fail-closed behaviour for eu_native claims (unproven residency blocks).
class AddCompanyDomicileToAiCredentials < ActiveRecord::Migration[8.0]
  def change
    # 'eu' | 'non_eu' — validated at the model, not the database, so admin
    # repair of legacy rows stays possible (house rule from the P1 concerns).
    add_column :ai_credentials, :company_domicile, :string
  end
end
