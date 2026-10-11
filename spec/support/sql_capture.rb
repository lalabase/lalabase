# frozen_string_literal: true

# Records the SQL a block runs, so an example can say "this asks the database
# once" or "this never touches that table" instead of only checking the result.
#
# Lives here rather than in the two specs that need it (TimeSessions::ViewingScope
# and TimeSessionPolicy::Scope, S0 of doc/projektzeiten_tabelle_plan.md): the same
# subscriber written twice drifts apart, and a query-count claim is worth exactly
# as much as the filter that produced it.
module SqlCapture
  # Bookkeeping every example produces anyway. Keeping it out is what lets a spec
  # assert an exact number instead of a fuzzy "less than".
  IGNORED = /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE SAVEPOINT)|pg_attribute|information_schema/i

  # => Array<String> of the statements the block ran, oldest first.
  def capture_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      sql = payload[:sql].to_s
      statements << sql unless payload[:name] == 'SCHEMA' || sql.match?(IGNORED)
    end

    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end

RSpec.configure { |config| config.include SqlCapture }
