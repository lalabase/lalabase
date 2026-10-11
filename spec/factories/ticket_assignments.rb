# frozen_string_literal: true

# == Schema Information
#
# Table name: ticket_assignments
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  ticket_id  :uuid             not null
#  user_id    :uuid             not null
#
# Indexes
#
#  index_ticket_assignments_on_ticket_id              (ticket_id)
#  index_ticket_assignments_on_ticket_id_and_user_id  (ticket_id,user_id) UNIQUE
#  index_ticket_assignments_on_user_id                (user_id)
#
FactoryBot.define do
  factory :ticket_assignment do
    user
    ticket
  end
end
