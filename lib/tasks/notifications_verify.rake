# frozen_string_literal: true

namespace :notifications do
  desc "Verify that in-app ticket status updates are suppressed for a user in an organisation. Usage: rake 'notifications:verify_suppression[ORG,EMAIL]'"
  task :verify_suppression, %i[org_identifier email] => :environment do |_t, args|
    identifier = args[:org_identifier] || ENV['ORG'] || ENV['ORG_ID'] || ENV['ORG_NAME']
    email      = args[:email] || ENV['EMAIL']

    unless identifier && email
      puts 'ERROR: Provide org and email. Examples:'
      puts "  rake 'notifications:verify_suppression[acme,demo@example.com]'"
      puts '  ORG=acme EMAIL=demo@example.com rake notifications:verify_suppression'
      exit 1
    end

    org = Organisation.find_by(id: identifier) ||
          Organisation.find_by(slug: identifier) ||
          Organisation.find_by(name: identifier) ||
          Organisation.find_by('LOWER(name) = ?', identifier.to_s.downcase)

    unless org
      puts "ERROR: Organisation not found for '#{identifier}'"
      exit 1
    end

    user = User.find_by(email: email)
    unless user
      puts "ERROR: User not found for '#{email}'"
      exit 1
    end

    puts "Organisation: #{org.id} #{org.try(:slug) || org.try(:name)}"
    puts "User:        #{user.id} #{user.email}"

    result = nil
    ActsAsTenant.with_tenant(org) do
      # 1) Persistently disable ticket_status_changed for in_app + email using the service (full-matrix safe)
      params = {
        'ticket_status_changed' => {
          'in_app' => { 'enabled' => '0' },
          'email' => { 'enabled' => '0' }
        }
      }

      result = Notifications::UpdatePreferencesService.call(
        user: user,
        organisation: org,
        preference_params: params,
        submitted_scope: nil,
        full_matrix: true
      )

      # 2) Verify persisted state
      in_app_pref = NotificationPreference.find_by(
        user: user,
        organisation: org,
        event_type: 'ticket_status_changed',
        channel: 'in_app'
      )
      email_pref = NotificationPreference.find_by(
        user: user,
        organisation: org,
        event_type: 'ticket_status_changed',
        channel: 'email'
      )

      puts "Prefs saved: success=#{result[:success]} created=#{result[:created_count]} updated=#{result[:updated_count]}"
      puts "in_app: enabled=#{in_app_pref&.enabled?} freq=#{in_app_pref&.frequency}"
      puts "email:  enabled=#{email_pref&.enabled?}  freq=#{email_pref&.frequency}"

      # 3) Create a synthetic activity (unsaved is fine) and check suppressor
      actor = User.where.not(id: user.id).first # avoid self-action; nil is acceptable
      activity = Activity.new(
        organisation: org,
        key: 'ticket.status_changed',
        action: 'ticket_updated',
        actor: actor
      )

      suppressor = Notifications::Suppressor.new(activity, user)
      muted = suppressor.send(:suppress_muted?)
      reasons = suppressor.suppression_reasons

      puts "suppress_muted?: #{muted} reasons=#{reasons.inspect}"

      if muted
        puts "SUCCESS: In-app status updates will be suppressed for #{email} in org #{org.id}."
        exit 0
      else
        puts 'FAIL: Suppressor did not mute. Investigate preferences and suppression logic.'
        exit 2
      end
    end
  rescue StandardError => e
    puts "ERROR: #{e.class}: #{e.message}"
    puts e.backtrace.take(5).join("\n")
    exit 3
  end
end
