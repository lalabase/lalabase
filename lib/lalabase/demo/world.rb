# frozen_string_literal: true

module Lalabase
  module Demo
    # Builds the Nordlicht fiction (Lalabase::Demo::Fiction) in one language, for the
    # product screenshots and for the public demo.
    #
    # Every write goes through the path a real instance uses: the organisation through
    # Actors::CreateOrganisation, tickets, notes, comments, meetings and hours through
    # their actors, projects the way Organisations::ProjectsController creates them.
    # No factories: the demo runs in production, where FactoryBot is not installed,
    # and a factory would show a state no real instance produces. Only the stored
    # assistant answer is written directly, because its actor would ask a model.
    #
    # Entry point: build. The order of writes is explicit: people before projects,
    # projects before tickets, tickets before the hours booked on them.
    #
    #   Lalabase::Demo::World.new(locale: :en).build
    #
    # `now` is the moment the world is seen from (frozen for the screenshots, the time
    # of the reset for the demo). `organisation` takes extra attributes for the
    # organisation, such as the AI switches. `embeddings` marks notes, comments and
    # meetings for the assistant's search.
    class World
      ORGANISATION_NAME = 'Nordlicht Software GmbH'

      attr_reader :organisation, :chat, :notes, :meetings

      def initialize(locale:, now: Time.current, organisation: {}, embeddings: false, password: nil)
        @locale = locale.to_sym
        @now = now
        @organisation_attributes = organisation
        @embeddings = embeddings
        @password = password || SecureRandom.base58(24)
        @people = {}
        @projects = {}
        @tickets = []
      end

      def person(key) = @people.fetch(key)
      def project(key) = @projects.fetch(key)
      def ticket(index) = @tickets.fetch(index)
      def signed_in = person(Fiction::SIGNED_IN)

      def build
        # The default smart folders and the role take their names from the locale at
        # creation, as they do for a real person who works in that language.
        I18n.with_locale(@locale) do
          create_organisation
          ActsAsTenant.with_tenant(@organisation) { build_inside }
        end
        self
      end

      private

      def build_inside
        role = add_team_role
        Fiction::PEOPLE.each_key do |key|
          next if key == Fiction::OWNER

          @people[key] = add_user(key)
          @people[key].memberships.create!(organisation: @organisation, role: role, active: true)
        end
        Fiction::PROJECTS.each_key { |key| @projects[key] = add_project(key) }
        add_tickets
        add_time
        add_notes
        add_comments
        add_meetings
        add_chat
      end

      def create_organisation
        owner = add_user(Fiction::OWNER)
        @people[Fiction::OWNER] = owner
        @organisation = Organisation.new(name: ORGANISATION_NAME, subdomain: 'nordlicht', domain: Fiction::DOMAIN,
                                         **@organisation_attributes)
        succeed!(Actors::CreateOrganisation.call(organisation: @organisation, owner: owner, current_user: owner))
      end

      # Confirmed right away: there is no inbox behind nordlicht.example.
      def add_user(key)
        User.create!(**Fiction::PEOPLE.fetch(key), email: Fiction.email(key),
                                                   password: @password, password_confirmation: @password,
                                                   language_preference: @locale.to_s, terms_accepted_at: @now,
                                                   &:skip_confirmation!)
      end

      def add_team_role
        definition = Fiction::TEAM_ROLE
        role = @organisation.roles.create!(title: definition[:title].fetch(@locale),
                                           description: definition[:description].fetch(@locale))
        definition[:permissions].each do |category, actions|
          actions.each { |action| role.permissions.create!(category: category, action: action, allowed: true) }
        end
        role
      end

      # Mirrors Organisations::ProjectsController#create with default attributes ticked.
      def add_project(key)
        entry = Fiction::PROJECTS.fetch(key)
        project = @organisation.projects.create!(name: entry.fetch(@locale),
                                                 description: entry[:description].fetch(@locale))
        Projects::DefaultAttributeService.new(project).call
        Projects::DefaultSmartFolderService.new(project).call(signed_in)
        add_members(project)
        project
      end

      # Mirrors Organisations::ProjectPermissionsController#create and its time
      # settings, without the activity entries a person adding a colleague leaves.
      def add_members(project)
        @people.each do |key, user|
          next if key == Fiction::OWNER

          project.project_permissions.create!(user: user, **Fiction::PROJECT_ACCESS)
          user.time_session_permission_for(project)
              .update!(key == Fiction::SIGNED_IN ? Fiction::LEAD_TIME_RIGHTS : {})
          Projects::DefaultSmartFolderService.new(project).create_my_tasks_for(user) unless key == Fiction::SIGNED_IN
        end
      end

      def add_tickets
        Fiction::TICKETS.each do |entry|
          params = { title: entry.fetch(@locale),
                     custom_attributes: { 'status' => entry[:status], 'priority' => entry[:priority] } }
          params[:assignee_ids] = [person(entry[:assignee]).id] if entry[:assignee]
          @tickets << succeed!(Actors::SaveTicket.call(project: project(:deichblick), params: params,
                                                       current_user: signed_in))
        end
        # Created over the last weeks, oldest first, so the list does not say "less
        # than a minute ago" nine times.
        @tickets.each_with_index do |ticket, index|
          backdate(ticket, @now - ((@tickets.size - index) * 3).days)
        end
      end

      def add_time
        Fiction::TIME.each do |entry|
          creator = person(entry[:person])
          session = TimeSession.new(organisation: @organisation, project: project(:deichblick),
                                    ticket: entry[:ticket] && ticket(entry[:ticket]), creator: creator,
                                    duration: entry[:minutes], occurred_on: booked_on(entry[:days_ago]),
                                    description: entry.fetch(@locale))
          succeed!(Actors::SaveTimeSession.call(time_session: session, attributes: {},
                                                group_change: { requested: false }, current_user: creator))
        end
      end

      # Never before the start of the week: the stored answer speaks of the hours of
      # "this week", and on a Monday two days back is the week before.
      def booked_on(days_ago) = [@now - days_ago.days, @now.beginning_of_week].max

      def add_notes
        @notes = Fiction::NOTES.each_with_index.map do |entry, index|
          params = { title: entry.fetch(@locale), content: dated(entry[:content].fetch(@locale)),
                     description: nil, create_embeddings: @embeddings }
          note = succeed!(Actors::SaveNote.call(project: project(:deichblick), params: params, current_user: signed_in))
          backdate(note, @now - (index + 1).weeks)
        end
      end

      def add_comments
        target = ticket(Fiction::CHAT[:ticket])
        Fiction::COMMENTS.each do |entry|
          params = { content: entry.fetch(@locale), create_embeddings: @embeddings }
          post = succeed!(Actors::SavePost.call(ticket: target, params: params, current_user: person(entry[:person])))
          backdate(post, @now - entry[:hours_ago].hours)
        end
      end

      def add_meetings
        @meetings = Fiction::MEETINGS.map do |entry|
          params = { title: entry[:title].fetch(@locale), occurred_at: @now - entry[:days_ago].days,
                     duration_minutes: entry[:minutes], transcript: entry[:transcript].fetch(@locale),
                     generated_summary: entry[:summary]&.fetch(@locale).to_s, create_embeddings: @embeddings,
                     participants: entry[:participants].map { |who| participant(who) } }
          succeed!(Actors::SaveMeeting.call(project: project(entry[:project]), params: params, current_user: signed_in))
        end
      end

      # A key is a person of the company, a string a guest without an account.
      def participant(who)
        return { display_name: who, user_id: nil } if who.is_a?(String)

        { display_name: Fiction.full_name(who), user_id: person(who).id }
      end

      # The first post of a chat renders as the question (Chatpost#set_initial_role
      # makes it 'system'). model_used marks the answer as finished; without it the [n]
      # links stay text.
      def add_chat
        spec = Fiction::CHAT
        @chat = Chat.new(organisation: @organisation, user: signed_in)
        @chat.chatposts.build(organisation: @organisation, user: signed_in, content: spec[:question].fetch(@locale))
        @chat.save!
        citations = [Lalabase::Citations.ticket(ticket(spec[:ticket])),
                     Lalabase::Citations.time_report(project(:deichblick), {}),
                     Lalabase::Citations.note(@notes.fetch(spec[:note]))]
        @chat.chatposts.create!(organisation: @organisation, user: signed_in, role: 'assistant',
                                content: dated(spec[:answer].fetch(@locale)), model_used: spec[:model],
                                source_citations: citations.map(&:deep_stringify_keys))
        @chat.chatposts.update_all(created_at: @now - 20.minutes)
      end

      def dated(text) = Fiction.dated(text, @locale, @now)

      def backdate(record, at)
        record.update_columns(created_at: at, updated_at: at)
        record
      end

      def succeed!(result)
        raise "Demo world: #{result.errors.to_sentence}" unless result.success?

        result.resource
      end
    end
  end
end
