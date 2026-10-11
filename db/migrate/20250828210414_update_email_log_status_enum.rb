class UpdateEmailLogStatusEnum < ActiveRecord::Migration[8.0]
  def up
    # Update existing enum values to accommodate new :delivered status
    # New mapping: queued=0, sent=1, delivered=2, bounced=3, complaint=4, opened=5, clicked=6, failed=7, deferred=8, unsubscribed=9
    
    # Temporarily map old values to prevent conflicts
    execute <<-SQL
      UPDATE email_logs SET status = status + 10 WHERE status >= 2;
    SQL
    
    # Now map to new values
    execute <<-SQL
      UPDATE email_logs SET status = 3 WHERE status = 12; -- bounced: 2 -> 3
      UPDATE email_logs SET status = 4 WHERE status = 13; -- complaint: 3 -> 4  
      UPDATE email_logs SET status = 5 WHERE status = 14; -- opened: 4 -> 5
      UPDATE email_logs SET status = 6 WHERE status = 15; -- clicked: 5 -> 6
      UPDATE email_logs SET status = 7 WHERE status = 16; -- failed: 6 -> 7
      UPDATE email_logs SET status = 8 WHERE status = 17; -- deferred: 7 -> 8
      UPDATE email_logs SET status = 9 WHERE status = 18; -- unsubscribed: 8 -> 9
    SQL
  end
  
  def down
    # Reverse the mapping
    execute <<-SQL
      UPDATE email_logs SET status = status + 10 WHERE status >= 3;
    SQL
    
    execute <<-SQL
      UPDATE email_logs SET status = 2 WHERE status = 13; -- bounced: 3 -> 2
      UPDATE email_logs SET status = 3 WHERE status = 14; -- complaint: 4 -> 3
      UPDATE email_logs SET status = 4 WHERE status = 15; -- opened: 5 -> 4
      UPDATE email_logs SET status = 5 WHERE status = 16; -- clicked: 6 -> 5
      UPDATE email_logs SET status = 6 WHERE status = 17; -- failed: 7 -> 6
      UPDATE email_logs SET status = 7 WHERE status = 18; -- deferred: 8 -> 7
      UPDATE email_logs SET status = 8 WHERE status = 19; -- unsubscribed: 9 -> 8
    SQL
    
    # Remove any delivered status (value 2) - set to sent
    execute <<-SQL
      UPDATE email_logs SET status = 1 WHERE status = 2;
    SQL
  end
end
