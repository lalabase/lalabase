# frozen_string_literal: true

namespace :system_settings do
  desc 'Initialize default system settings'
  task initialize: :environment do
    puts 'Initializing system settings...'

    # Initialize all default settings
    SystemSetting.initialize_defaults

    # Specifically ensure grace period is set
    if SystemSetting.exists?(key: 'account_deletion_grace_period_days')
      puts '✓ account_deletion_grace_period_days already exists'
    else
      SystemSetting.create!(
        key: 'account_deletion_grace_period_days',
        value: '30',
        data_type: 'integer',
        description: 'Wartezeit in Tagen bevor ein Account endgültig gelöscht wird (0-365)'
      )
      puts '✓ Created account_deletion_grace_period_days setting (30 days)'
    end

    puts 'System settings initialized successfully!'
  end
end
