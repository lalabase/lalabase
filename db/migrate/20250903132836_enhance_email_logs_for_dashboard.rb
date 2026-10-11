class EnhanceEmailLogsForDashboard < ActiveRecord::Migration[8.0]
  def change
    # Store email content
    add_column :email_logs, :body_html_compressed, :binary
    add_column :email_logs, :body_text, :text
    add_column :email_logs, :body_preview, :text, limit: 500
    
    # Essential email fields for dashboard
    add_column :email_logs, :recipient_email, :string
    add_column :email_logs, :subject, :string
    add_column :email_logs, :sent_at, :datetime
    add_column :email_logs, :delivered_at, :datetime
    add_column :email_logs, :opened_at, :datetime
    add_column :email_logs, :clicked_at, :datetime
    add_column :email_logs, :bounced_at, :datetime
    add_column :email_logs, :failed_at, :datetime
    
    # Tracking & metrics
    add_column :email_logs, :open_count, :integer, default: 0
    add_column :email_logs, :click_count, :integer, default: 0
    add_column :email_logs, :retry_count, :integer, default: 0
    add_column :email_logs, :bounce_type, :string # hard, soft, complaint
    add_column :email_logs, :failure_reason, :text
    
    # For resend functionality
    add_column :email_logs, :resent_from_id, :uuid
    add_column :email_logs, :can_retry, :boolean, default: true
    
    # Indexes for dashboard queries
    add_index :email_logs, [:organisation_id, :sent_at]
    add_index :email_logs, [:organisation_id, :status]
    add_index :email_logs, :recipient_email
    add_index :email_logs, :sent_at
    add_index :email_logs, [:status, :created_at]
    add_index :email_logs, :resent_from_id
    
    # Foreign key for resend tracking
    add_foreign_key :email_logs, :email_logs, column: :resent_from_id
  end
end