class AddCustomerDescriptionToTimeSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :time_sessions, :customer_description, :text
    add_index :time_sessions, :customer_description,
              where: "customer_description IS NOT NULL",
              name: 'index_time_sessions_on_customer_description'
  end
end
