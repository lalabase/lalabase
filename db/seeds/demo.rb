# frozen_string_literal: true

# A small demo for a fresh development database, so a contributor has something to
# click on: one organisation with one person per role (admin, default, project
# manager, viewer), the onboarding tutorial and one sample project with a handful of
# tickets, plus an instance admin for /admin. Signing in as each person shows what
# the role changes.
#
# Loaded by db/seeds.rb in development only, and refuses on its own in production.
# Idempotent: when the demo organisation's admin exists, it does nothing. Start over
# with `bin/rails db:reset`.
#
# Everything goes through the paths a real instance uses (Actors::CreateSignup,
# Actors::SaveTicket, the project default services), so the demo breaks loudly when
# those change instead of quietly showing a state no real signup produces.
module DemoSeed
  PASSWORD = 'lalabase-demo'
  LANGUAGE = 'de'
  ADMIN_EMAIL = 'anna@example.com'
  MEMBER_EMAIL = 'ben@example.com'
  BEUSER_EMAIL = 'admin@example.com'
  ORGANISATION_NAME = 'Beispiel GmbH'

  # Read access to every project, one right per area.
  READ_ALL_PROJECTS = %w[
    read_access_chats_all_projects
    read_access_notes_all_projects
    read_access_meetings_all_projects
    read_access_tickets_all_projects
    read_access_documents_all_projects
    read_access_time_tracking_all_projects
  ].freeze

  # Example roles next to the two every organisation has (account_admin and the
  # default role). All rights are in the 'projects' permission category.
  ROLES = {
    'Projektmanager' => { description: 'Kann Projekte verwalten und erstellen',
                          actions: %w[change_project_properties create_new_projects] + READ_ALL_PROJECTS },
    'Betrachter' => { description: 'Kann alle Projekte einsehen, aber nicht bearbeiten',
                      actions: READ_ALL_PROJECTS }
  }.freeze

  # role: nil is the organisation's default role.
  PEOPLE = [
    { email: MEMBER_EMAIL, first_name: 'Ben', last_name: 'Beispiel', role: nil },
    { email: 'clara@example.com', first_name: 'Clara', last_name: 'Planer', role: 'Projektmanager' },
    { email: 'david@example.com', first_name: 'David', last_name: 'Leser', role: 'Betrachter' }
  ].freeze

  PROJECT = { name: 'Website-Relaunch', description: 'Neue Website bis Ende des Quartals.' }.freeze
  # status / priority are option values of Projects::DefaultAttributeService.
  TICKETS = [
    { title: 'Sitemap abstimmen', status: 'resolved', priority: 'normal' },
    { title: 'Texte für die Startseite schreiben', status: 'in_progress', priority: 'high', member: true },
    { title: 'Fotos für das Team-Kapitel besorgen', status: 'new', priority: 'normal', member: true },
    { title: 'Kontaktformular testen', status: 'new', priority: 'low' },
    { title: 'Impressum und Datenschutz prüfen', status: 'new', priority: 'urgent' }
  ].freeze

  module_function

  def run
    raise 'The demo seed is for development only.' if Rails.env.production?
    return $stdout.puts('Demo exists already, nothing to do.') if User.exists?(email: ADMIN_EMAIL)

    admin, organisation = sign_up_admin
    ActsAsTenant.with_tenant(organisation) do
      roles = create_roles(organisation)
      PEOPLE.each { |person| add_member(organisation, person, roles.fetch(person[:role]) { organisation.find_or_create_default_role }) }
      create_project(organisation, admin, User.find_by!(email: MEMBER_EMAIL))
    end
    create_beuser

    $stdout.puts <<~TEXT
      Demo ready. Password for all accounts: #{PASSWORD}
        App:   #{ADMIN_EMAIL} (admin), #{PEOPLE.map { |person| "#{person[:email]} (#{person[:role] || 'default role'})" }.join(', ')}
        Admin: #{BEUSER_EMAIL} at /admin
    TEXT
  end

  # The signup also seeds the onboarding tutorial project. Confirmed right away: there
  # is no inbox behind example.com to click a confirmation link in.
  def sign_up_admin
    result = Actors::CreateSignup.call(
      email: ADMIN_EMAIL, password: PASSWORD, password_confirmation: PASSWORD,
      first_name: 'Anna', last_name: 'Admin', language: LANGUAGE,
      terms_accepted: true, organisation_name: ORGANISATION_NAME
    )
    raise "Demo signup failed: #{result.errors.to_sentence}" unless result.success?

    admin = result.resource
    admin.confirm
    [admin, admin.organisations.find_by!(name: ORGANISATION_NAME)]
  end

  def create_roles(organisation)
    ROLES.to_h do |title, definition|
      role = organisation.roles.create!(title: title, description: definition[:description])
      definition[:actions].each { |action| role.permissions.create!(category: 'projects', action: action, allowed: true) }
      [title, role]
    end
  end

  # Joins the way Admin::UsersController adds someone to an existing organisation:
  # a user and a membership with the chosen role.
  def add_member(organisation, person, role)
    member = User.create!(email: person[:email], password: PASSWORD, password_confirmation: PASSWORD,
                          first_name: person[:first_name], last_name: person[:last_name],
                          language_preference: LANGUAGE, terms_accepted_at: Time.current, &:skip_confirmation!)
    member.memberships.create!(organisation: organisation, role: role, active: true)
  end

  # Mirrors Organisations::ProjectsController#create with default attributes ticked, and
  # grants the member read-write tickets like the project permissions page would.
  def create_project(organisation, admin, member)
    project = organisation.projects.create!(PROJECT)
    Projects::DefaultAttributeService.new(project).call
    Projects::DefaultSmartFolderService.new(project).call(admin)
    project.project_permissions.create!(user: member, tickets_access: :read_write)
    Projects::DefaultSmartFolderService.new(project).create_my_tasks_for(member)

    TICKETS.each do |ticket|
      params = { title: ticket[:title],
                 custom_attributes: { 'status' => ticket[:status], 'priority' => ticket[:priority] } }
      params[:assignee_ids] = [member.id] if ticket[:member]
      result = Actors::SaveTicket.call(project: project, params: params, current_user: admin)
      raise "Demo ticket failed: #{result.errors.to_sentence}" unless result.success?
    end
  end

  def create_beuser
    Beuser.find_or_create_by!(email: BEUSER_EMAIL) do |beuser|
      beuser.assign_attributes(password: PASSWORD, password_confirmation: PASSWORD, role: 'admin', active: true)
    end
  end
end

DemoSeed.run
