# frozen_string_literal: true

# L10 of doc/ki_bereich_navigation_plan.md — the state "chosen, but broken".
#
# Until now a connection test lived only as a flash message: the admin saw "erfolgreich"
# once and the app forgot it. Two consequences the plan names, both of which this pair of
# columns closes:
#   * the access page cannot say "zuletzt geprüft am …", so nothing distinguishes an
#     access that works from one nobody has ever tried;
#   * the AI hub card carries the state "Verbindung fehlerhaft" (§3.2) that it can never
#     reach — S2 shipped the card deliberately without that branch and named the missing
#     columns as the reason.
#
# The only migration this plan asks for.
class AddAiConnectionStateToOrganisations < ActiveRecord::Migration[8.0]
  def change
    change_table :organisations, bulk: true do |t|
      # NULL means "never tested", which is a state of its own and NOT the same as
      # "failed": an organisation that has just entered its key has not failed anything.
      # The access card renders the two differently for that reason.
      t.column :ai_connection_checked_at, :datetime

      # The OUTCOME, not the message. A provider's error text belongs in the log and in
      # the flash of the request that produced it; storing it here would put a
      # third-party string into a column the settings page renders on every visit, and it
      # would age into a claim nobody can verify. Values are decided by the reader, not
      # by the column — see Organisation for the two it uses.
      t.column :ai_connection_status, :string
    end
  end
end
