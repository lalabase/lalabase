class RemoveContentFromTickets < ActiveRecord::Migration[8.0]
  def change
    remove_column :tickets, :content, :text
  end
end
