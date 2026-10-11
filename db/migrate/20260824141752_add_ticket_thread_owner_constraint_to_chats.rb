# frozen_string_literal: true

# T2 third second-review finding: TWO mechanisms consume "user_id means single
# reader" -- the render gate's owner short-circuit and the account erasure
# (PersonalChatErasure destroys Chat.where(user_id:)). The model validation
# (ticket_thread_has_no_owner) guards normal writes, but the smuggle paths the
# finding names (console update_columns, imports) bypass validations -- NOT
# constraints. This closes the state at the source until S4 gives ticket
# threads owners through a deliberate migration of its own (plan §13-3).
class AddTicketThreadOwnerConstraintToChats < ActiveRecord::Migration[8.0]
  def change
    add_check_constraint :chats,
                         'ticket_id IS NULL OR user_id IS NULL',
                         name: 'chats_ticket_thread_has_no_owner'
  end
end
