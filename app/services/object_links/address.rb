# frozen_string_literal: true

# Entry point: .parse
module ObjectLinks
  # Reads one link address and names the object of this instance it points at, or nil.
  #
  # An object has two address forms, and both count:
  #
  #   * its page: /org/:o/projects/:p/tickets/:id, /org/:o/people/members/:user_id, ...
  #   * the lane parameter of an overview: /org/:o/meetings?meeting_id=, ?person_id=, ...
  #
  # The route is recognised by the router, not by a pattern per type, so a renamed route
  # stops being recognised instead of being recognised wrongly. Which overview reads which
  # parameter is LANE_PARAMS, read from the controllers (TicketsController,
  # MeetingsOverviewController, MeetingsController, PeopleController, NotesController,
  # KnowledgeController with Knowledge::TypeRegistry).
  #
  # Only an address of this instance and of the current organisation names anything:
  #
  #   * the host is one of `hosts` (a String compares whole and case-insensitively, a
  #     Regexp must match the whole host), or there is none (a path of this instance);
  #   * the path's organisation is `organisation_id` (E4: a link into another organisation
  #     stays a link, even for a reader who is a member there);
  #   * no credentials, http or https, no format.
  #
  # A Ref says what the address NAMES. Whether that object exists and whether the reader may
  # read it is ObjectLinks::Targets' question.
  module Address
    # type: :ticket, :meeting, :person, :member, :note, :document. project_id is the
    # project the address names (nil where the address has none): a ticket under the wrong
    # project is a dead link and gets no chip.
    Ref = Data.define(:type, :id, :project_id)

    SCHEMES = %w[http https].freeze

    # controller#action of an object's page => [type, the path parameter of its id]
    PAGES = {
      'organisations/tickets#show' => %i[ticket id],
      'organisations/meetings#show' => %i[meeting id],
      'organisations/notes#show' => %i[note id],
      'organisations/documents#show' => %i[document id],
      'organisations/people#show' => %i[person id],
      'organisations/people#member' => %i[member user_id]
    }.freeze

    # controller#action of an overview => its lane parameters in the order it reads them
    LANE_PARAMS = {
      'organisations/tickets#index' => { 'ticket_id' => :ticket },
      'organisations/meetings_overview#index' => { 'meeting_id' => :meeting },
      'organisations/meetings#index' => { 'meeting_id' => :meeting },
      'organisations/people#index' => { 'person_id' => :person, 'member_id' => :member },
      'organisations/notes#index' => { 'note_id' => :note },
      'organisations/knowledge#index' => { 'note_id' => :note, 'document_id' => :document }
    }.freeze

    module_function

    def parse(href, organisation_id:, hosts:)
      uri = own_uri(href, hosts)
      return nil if uri.nil?

      route = recognize(uri.path)
      return nil if route.nil? || route[:format].present?
      return nil unless Lalabase::Uuid.dashed(route[:organisation_id]) == organisation_id.to_s

      ref_for(route, uri.query)
    end

    def own_uri(href, hosts)
      uri = URI.parse(href.to_s.strip)
      return nil if uri.path.blank? || uri.userinfo.present?
      return uri if uri.scheme.nil? && uri.host.nil? && uri.path.start_with?('/')
      return nil unless SCHEMES.include?(uri.scheme&.downcase) && own_host?(uri.host, hosts)

      uri
    rescue URI::Error
      nil
    end

    def own_host?(host, hosts)
      return false if host.blank?

      Array(hosts).any? do |allowed|
        case allowed
        when Regexp then /\A(?:#{allowed.source})\z/i.match?(host)
        else allowed.to_s.casecmp?(host)
        end
      end
    end

    def recognize(path)
      return nil unless path.start_with?('/org/')

      Rails.application.routes.recognize_path(path, method: :get)
    rescue ActionController::RoutingError
      nil
    end

    def ref_for(route, query)
      key = "#{route[:controller]}##{route[:action]}"
      project_id = route[:project_id] && Lalabase::Uuid.dashed(route[:project_id])
      return nil if route[:project_id] && project_id.nil?

      if (page = PAGES[key])
        build(page.first, route[page.last], project_id)
      elsif (params = LANE_PARAMS[key])
        lane_ref(params, query, project_id)
      end
    end

    def lane_ref(params, query, project_id)
      values = Rack::Utils.parse_query(query.to_s)
      params.each do |name, type|
        value = values[name]
        return build(type, value, project_id) if value.is_a?(String) && value.present?
      end
      nil
    end

    def build(type, raw_id, project_id)
      id = Lalabase::Uuid.dashed(raw_id)
      Ref.new(type: type, id: id, project_id: project_id) if id
    end

    private_class_method :own_uri, :own_host?, :recognize, :ref_for, :lane_ref, :build
  end
end
