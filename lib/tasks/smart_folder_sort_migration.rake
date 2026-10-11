# frozen_string_literal: true

namespace :smart_folders do
  desc 'Migrate sort_by integer values to sort_column/sort_direction string fields'
  task migrate_sort_fields: :environment do
    # Mapping: sort_by integer => [sort_column, sort_direction]
    SORT_BY_MAPPING = {
      0 => %w[updated_at desc],
      1 => %w[updated_at asc],
      2 => %w[created_at desc],
      3 => %w[created_at asc],
      4 => %w[title asc],
      5 => %w[title desc]
    }.freeze

    # Ensure model sees newly added columns
    SmartFolder.reset_column_information

    migrated = 0
    skipped = 0

    # Bypass acts_as_tenant scope for data migration
    Organisation.find_each do |org|
      ActsAsTenant.with_tenant(org) do
        SmartFolder.find_each do |sf|
          # Skip if already migrated
          if sf.sort_column.present?
            skipped += 1
            next
          end

          mapping = SORT_BY_MAPPING[sf.sort_by] || %w[updated_at desc]
          sf.update_columns(sort_column: mapping[0], sort_direction: mapping[1])
          migrated += 1
        end
      end
    end

    puts "Smart Folder sort migration complete: #{migrated} migrated, #{skipped} skipped (already had sort_column)"
  end
end
