# frozen_string_literal: true

class ImportUsersFromCodebaseJob < ApplicationJob
  queue_as :default

  def perform(import_file_id, user_actions, user_roles, importing_user_id)
    import_file = CodebaseImportFile.find(import_file_id)
    importing_user = User.find(importing_user_id)
    organisation = import_file.organisation

    ActsAsTenant.with_tenant(organisation) do
      import_file.update!(status: 'processing', processed_at: Time.current)

      parsed_data = import_file.parsed_data || []
      results = {
        total: parsed_data.count,
        created: 0,
        mapped: 0,
        skipped: 0,
        failed: 0
      }

      parsed_data.each do |user_data|
        codebase_id = user_data[:id].to_s
        action = user_actions[codebase_id]
        role_id = user_roles[codebase_id]

        case action
        when 'create'
          result = create_new_user(user_data, organisation, role_id, importing_user)
          results[result[:status]] += 1

        when /\Amap:(.+)\z/
          existing_user_id = Regexp.last_match(1)
          result = map_to_existing_user(user_data, existing_user_id, organisation)
          results[result[:status]] += 1

        when 'skip'
          results[:skipped] += 1

        else
          Rails.logger.warn "Unknown action '#{action}' for user #{codebase_id}"
          results[:failed] += 1
        end
      end

      import_file.update!(
        status: 'processed',
        metadata: (import_file.metadata || {}).merge('import_results' => results)
      )

      Rails.logger.info "User import completed: #{results}"
    rescue StandardError => e
      import_file.update!(
        status: 'error',
        metadata: (import_file.metadata || {}).merge('error' => e.message)
      )
      Rails.logger.error "User import failed: #{e.message}"
      raise
    end
  end

  private

  def create_new_user(user_data, organisation, role_id, importing_user)
    name_parts = extract_name_parts(user_data[:full_name])

    ActiveRecord::Base.transaction do
      # skip_confirmation! in the block, i.e. BEFORE the insert (:confirmable
      # mails from an after_create callback). An import is an admin action over
      # a vouched-for address list: the imported people never signed up, carry a
      # random password and have no context for a confirmation link. Without
      # this, every import row mails a stranger a link nobody clicks — and all
      # of those accounts lock themselves out when the grace period ends.
      user = User.create!(
        email: user_data[:email],
        first_name: name_parts[:first_name],
        last_name: name_parts[:last_name],
        password: SecureRandom.hex(16),
        invited_by_user: importing_user,
        invited_by_org: organisation,
        &:skip_confirmation!
      )

      role = organisation.roles.find(role_id) if role_id.present?
      role ||= organisation.roles.find_by(is_default: true)

      Membership.create!(
        user: user,
        organisation: organisation,
        role: role,
        active: false
      )

      CodebaseImportMapping.create!(
        codebase_id: user_data[:id],
        local_id: user.id,
        entity_type: 'User',
        mapping_data: {
          original_data: user_data,
          action: 'created'
        }
      )

      { status: :created, user: user }
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ActiveRecord::RecordNotUnique => e
    Rails.logger.error "Failed to create user #{user_data[:email]}: #{e.message}"
    { status: :failed, error: e.message }
  end

  # The id comes from the request; the preview only offers members. User carries no
  # tenant, so without the organisation here any account of the instance could become
  # the author of imported tickets, posts and time entries.
  def map_to_existing_user(user_data, existing_user_id, organisation)
    existing_user = organisation.users.find(existing_user_id)

    CodebaseImportMapping.create!(
      codebase_id: user_data[:id],
      local_id: existing_user.id,
      entity_type: 'User',
      mapping_data: {
        original_data: user_data,
        action: 'mapped'
      }
    )

    { status: :mapped, user: existing_user }
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ActiveRecord::RecordNotUnique => e
    Rails.logger.error "Failed to map user #{user_data[:email]}: #{e.message}"
    { status: :failed, error: e.message }
  end

  def extract_name_parts(full_name)
    return { first_name: '', last_name: '' } if full_name.blank?

    parts = full_name.strip.split(/\s+/)

    if parts.length == 1
      { first_name: parts[0], last_name: '' }
    else
      { first_name: parts[0], last_name: parts[1..].join(' ') }
    end
  end
end
