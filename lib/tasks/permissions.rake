# frozen_string_literal: true

namespace :permissions do
  desc 'Remove stored role permissions whose action the code no longer knows (a data backfill)'
  task prune_unknown_actions: :environment do
    removed = ActsAsTenant.without_tenant { Permission.unknown_actions.delete_all }
    puts "permissions:prune_unknown_actions: #{removed} stored permissions removed."
  end
end
