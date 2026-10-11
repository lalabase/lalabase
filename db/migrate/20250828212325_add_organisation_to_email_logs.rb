class AddOrganisationToEmailLogs < ActiveRecord::Migration[8.0]
  def change
    # Add organisation_id column without null constraint first (UUID type to match organisations.id)
    add_reference :email_logs, :organisation, null: true, foreign_key: true, type: :uuid
    
    # Populate organisation_id from notification.organisation_id for existing records
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE email_logs 
          SET organisation_id = notifications.organisation_id
          FROM notifications 
          WHERE email_logs.notification_id = notifications.id
        SQL
        
        # Now make the column non-null
        change_column_null :email_logs, :organisation_id, false
      end
    end
  end
end
