class AddLockVersionToEmailLogs < ActiveRecord::Migration[8.0]
  def change
    # Add optimistic locking to prevent concurrent modifications
    add_column :email_logs, :lock_version, :integer, default: 0, null: false
    
    # Add composite index for better dashboard query performance
    add_index :email_logs, [:organisation_id, :status, :created_at], 
              name: 'idx_email_logs_dashboard'
    
    # Add index for provider message ID lookups (webhooks)
    add_index :email_logs, :provider_message_id, 
              where: 'provider_message_id IS NOT NULL',
              name: 'idx_email_logs_provider_msg'
  end
end
