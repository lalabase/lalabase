# frozen_string_literal: true

# lib/tasks/stimulus_custom.rake

namespace :stimulus do
  namespace :manifest do
    desc 'Update stimulus manifest but preserve custom index.js'
    task update_safe: :environment do
      puts '🔧 Updating Stimulus manifest (preserving custom index.js)...'

      # Backup current index.js
      backup_path = Rails.root.join('app/javascript/controllers/index.js.backup')
      index_path = Rails.root.join('app/javascript/controllers/index.js')

      if File.exist?(index_path)
        FileUtils.cp(index_path, backup_path)
        puts '✅ Backed up custom index.js'
      end

      # Run standard manifest update
      Rake::Task['stimulus:manifest:update'].invoke

      # Restore our custom version
      if File.exist?(backup_path)
        custom_content = <<~JS
          // Configure Stimulus development experience
          import { application } from "controllers/application"
          import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"

          // Eager load all controllers defined in the importmap
          // This uses the importmap to resolve controller paths with proper hashing
          eagerLoadControllersFrom("controllers", application)
        JS

        File.write(index_path, custom_content)
        puts '✅ Restored custom index.js'

        # Clean up backup
        FileUtils.rm(backup_path)
      end

      puts '🎉 Stimulus manifest updated with custom index.js preserved!'
    end
  end
end
