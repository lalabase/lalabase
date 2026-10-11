# frozen_string_literal: true

# Once after the deploy of the private-comment fix (27.09.2026): before it, every
# comment left a text excerpt in its post_added activity and in the notifications
# copied from it, private ones included. New private comments store none, and a
# comment that turns private loses it on save; this removes what older ones left.
# Idempotent, per organisation.
namespace :posts do
  desc 'Remove the text excerpt of private comments from activities and notifications (all organisations, or one by id)'
  task :redact_private_excerpts, [:organisation_id] => :environment do |_task, args|
    organisations = args[:organisation_id].present? ? Organisation.where(id: args[:organisation_id]) : Organisation.all
    abort "No organisation #{args[:organisation_id]}" if args[:organisation_id].present? && organisations.none?

    organisations.find_each do |organisation|
      cleaned = ActsAsTenant.with_tenant(organisation) do
        Post.private_posts.where(id: Activity.where(action: 'post_added', secondary_type: 'Post')
                                             .where("activities.parameters->>'post_excerpt' IS NOT NULL")
                                             .select(:secondary_id))
            .find_each.sum { |post| Posts::ExcerptRedaction.call(post: post) }
      end
      puts "#{organisation.name} (#{organisation.id}): #{cleaned} activities cleaned"
    end
    puts 'Done.'
  end
end
