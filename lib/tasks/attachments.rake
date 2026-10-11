# frozen_string_literal: true

# Read-only counterpart to UnattachedBlobPurgeJob: shows what the next run would
# delete, without deleting anything. Meant to be run BY HAND once before the job
# goes live on a system, and afterwards whenever the log looks surprising.
#
# A deliberate one-off command instead of a permanent dry-run flag — see the job
# for why this codebase does not want a second EMBEDDINGS_GC_ENFORCE.
namespace :attachments do
  desc 'Report Active Storage blobs the purge job would delete (no deletion)'
  task unattached_report: :environment do
    grace = UnattachedBlobPurgeJob::GRACE_PERIOD
    all = ActiveStorage::Blob.unattached
    due = all.where(created_at: ...grace.ago)

    puts "Unattached blobs total:      #{all.count} (#{number_to_human_size_safe(all.sum(:byte_size))})"
    puts "Within grace period (#{grace.in_days.to_i}d):  #{all.count - due.count} — protected, may still be attached"
    puts "Due for purge:               #{due.count} (#{number_to_human_size_safe(due.sum(:byte_size))})"
    puts "Would purge in one run:      #{[due.count, UnattachedBlobPurgeJob::MAX_PER_RUN].min} (limit #{UnattachedBlobPurgeJob::MAX_PER_RUN})"
    puts

    if due.any?
      puts 'Oldest 20 due for purge:'
      due.order(:created_at).limit(20).each do |blob|
        puts format('  %<date>s  %<size>10s  %<type>-28s %<name>s',
                    date: blob.created_at.to_date,
                    size: number_to_human_size_safe(blob.byte_size),
                    type: blob.content_type.to_s.truncate(28),
                    name: blob.filename.to_s.truncate(60))
      end
      puts
      puts 'By content type:'
      due.group(:content_type).count.sort_by { |_, count| -count }.each do |type, count|
        puts format('  %<count>5d  %<type>s', count: count, type: type)
      end
    end
  end

  def number_to_human_size_safe(bytes)
    ActiveSupport::NumberHelper.number_to_human_size(bytes || 0)
  end
end
