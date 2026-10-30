# frozen_string_literal: true

class CodebaseImport::UserMatcher
  def initialize(organisation)
    @organisation = organisation
  end

  def analyze(parsed_users)
    # Pre-load all org users to avoid per-user queries
    @active_users = @organisation.users.active.to_a

    # Pre-fetch global users by email for suggest_action lookups
    emails = parsed_users.map { |u| u[:email] }.compact.uniq
    @global_users_by_email = User.where(email: emails).index_by(&:email)
    @org_user_ids = @active_users.map(&:id).to_set

    # Cache role lookups (same for all users)
    load_roles!

    parsed_users.map do |user_data|
      matches = find_potential_matches(user_data)
      {
        codebase_data: user_data,
        existing_matches: matches,
        suggested_action: suggest_action(user_data, matches),
        suggested_role: suggest_role(user_data)
      }
    end
  end

  private

  def active_users
    @active_users ||= @organisation.users.active.to_a
  end

  def load_roles!
    @roles_loaded = true
    @admin_role = @organisation.roles.where('LOWER(title) LIKE ?', '%admin%').first
    @default_role = @organisation.roles.find_by(is_default: true)
    @fallback_role = @default_role || @organisation.roles.first
  end

  def find_potential_matches(user_data)
    email = user_data[:email]
    full_name = user_data[:full_name]

    matches = []

    # 1. Exact email match (from pre-loaded users)
    exact_email_match = active_users.find { |u| u.email == email }
    if exact_email_match
      matches << {
        user: exact_email_match,
        match_type: :exact_email,
        confidence: :high,
        reason: 'Identische E-Mail-Adresse'
      }
    end

    # 2. Similar email addresses (same domain, from pre-loaded users)
    if email.present?
      domain = email.split('@').last
      # The email each member shows to others (User::EmailDisplay), not the
      # login address: the preview names the member next to the match, which
      # would confirm the domain of a hidden address. The exact match above
      # stays on the login address, it is how an import finds the account.
      similar_emails = active_users.select { |u| u.email != email && u.shown_email&.end_with?("@#{domain}") }
                                   .first(3)

      similar_emails.each do |user|
        matches << {
          user: user,
          match_type: :similar_email,
          confidence: :medium,
          reason: "Gleiche Domain (#{domain})"
        }
      end
    end

    # 3. Similar names (fuzzy matching, from pre-loaded users)
    if full_name.present?
      name_parts = full_name.downcase.split(/\s+/)

      similar_names = active_users.select do |user|
        name_parts.any? do |part|
          user.first_name&.downcase&.include?(part) || user.last_name&.downcase&.include?(part)
        end
      end.first(3)

      similar_names.each do |user|
        next if matches.any? { |m| m[:user].id == user.id }

        matches << {
          user: user,
          match_type: :similar_name,
          confidence: :low,
          reason: "Ähnlicher Name (#{user.full_name})"
        }
      end
    end

    matches
  end

  def suggest_action(user_data, matches = nil)
    # When called via analyze, matches are pre-computed; otherwise compute them
    matches ||= find_potential_matches(user_data)

    exact_match = matches.find { |m| m[:match_type] == :exact_email }
    return :use_existing if exact_match

    # Use pre-fetched global users when available, fall back to DB query
    global_user = if @global_users_by_email
                    @global_users_by_email[user_data[:email]]
                  else
                    User.find_by(email: user_data[:email])
                  end

    org_user_ids = @org_user_ids || active_users.map(&:id).to_set
    return :invite_to_organisation if global_user && !org_user_ids.include?(global_user.id)

    :create_new
  end

  def suggest_role(user_data)
    load_roles! unless @roles_loaded

    codebase_role = user_data[:role][:name]
    is_admin = user_data[:role][:account_administrator]

    return @admin_role.id if (is_admin || codebase_role&.downcase&.include?('admin')) && @admin_role

    @fallback_role&.id
  end
end
