# frozen_string_literal: true

module Api
  module V1
    class TicketsController < BaseController
      include Api::V1::ReadableTicket

      MAX_PER_PAGE = 100
      DEFAULT_PER_PAGE = 25

      # Maps an actor Result#code to an HTTP status. Unknown/legacy codes fall
      # back to 422 — the historical behaviour for any actor failure — so this is
      # purely additive: only the listed codes get a more precise status.
      ACTOR_ERROR_STATUS = {
        validation_failed: :unprocessable_entity,
        not_member: :forbidden,
        conflict: :conflict,
        stale_object: :conflict
      }.freeze

      def index
        project = load_project_without_tenant(params[:project_id])

        with_project_scope(project) do
          authorize project, :show?

          # Filtering/ordering/pagination is shared with the MCP list_tickets tool
          # via Tickets::Filter so the two surfaces cannot drift (cf. the shared
          # Tickets::Serializer). Authorization scoping stays here in the controller.
          filter = Tickets::Filter.new(params, current_user: current_user)
          scope = filter.ordered(filter.filtered(policy_scope(project.tickets)))
                        .includes(:creator, :assignees)

          render json: {
            data: filter.paginate(scope).map { |t| ticket_serializer.summary(t) },
            meta: { page: filter.page, per_page: filter.per_page, total: filter.total(scope) }
          }
        end
      end

      # POST /api/v1/projects/:project_id/tickets
      def create
        project = load_project_without_tenant(params[:project_id])

        with_project_scope(project) do
          authorize project, :show?
          authorize project.tickets.build, :create?

          result = Actors::SaveTicket.call(
            project: project,
            params: save_ticket_create_params,
            current_user: current_user
          )

          if result.success?
            render json: {
              data: ticket_serializer.full(result.resource),
              permissions: serialize_permissions(result.resource)
            }, status: :created
          else
            render_actor_failure(result)
          end
        end
      end

      def show
        with_readable_ticket(params[:id], preload: %i[creator assignees]) do |ticket|
          render json: {
            data: ticket_serializer.full(ticket),
            permissions: serialize_permissions(ticket)
          }
        end
      end

      # PATCH /api/v1/tickets/:id
      # Allowed fields: status, assignee_ids (replace semantics).
      def update
        with_readable_ticket(params[:id]) do |ticket, project|
          authorize ticket, :update?

          result = Actors::SaveTicket.call(
            project: project,
            params: save_ticket_update_params(ticket),
            id: ticket.id,
            current_user: current_user
          )

          if result.success?
            render json: { data: ticket_serializer.summary(result.resource) }
          else
            render_actor_failure(result)
          end
        end
      end

      def activities
        with_readable_ticket(params[:id]) do |ticket, project|
          return render json: { data: [], meta: pagination_meta(0) } unless ProjectPolicy.new(current_user, project).view_activities?

          relation = ticket.activities.includes(:actor).order(created_at: :desc)
          paged, total = paginate(relation)

          render json: {
            data: paged.map { |a| serialize_activity(a) },
            meta: pagination_meta(total)
          }
        end
      end

      def attachments
        with_readable_ticket(params[:id]) do |ticket|
          docs = collect_attachments(ticket)
          render json: { data: docs }
        end
      end

      private

      # Renders an actor failure Result. The machine-readable code becomes both
      # the `error` field and (via ACTOR_ERROR_STATUS) the HTTP status, so a
      # client can distinguish validation (422) from a conflict (409) etc.
      def render_actor_failure(result)
        render json: { error: result.code, errors: result.errors },
               status: ACTOR_ERROR_STATUS.fetch(result.code, :unprocessable_entity)
      end

      # --- Create helpers --------------------------------------------------

      def ticket_create_params
        @ticket_create_params ||= params.require(:ticket).permit(
          :title, :summary, :ticket_type, :description, :parent_id,
          assignee_ids: [],
          custom_attributes: {}
        ).to_h.symbolize_keys
      end

      # Maps the API create whitelist onto the params hash Actors::SaveTicket
      # expects (it assign_attributes-es everything except assignee_ids). Routing
      # creation through the same write seam as the web UI keeps assignee sync,
      # activity tracking and embeddings consistent across both paths.
      def save_ticket_create_params
        attrs = ticket_create_params
        mapped = {
          title: attrs[:title],
          summary: attrs[:summary],
          ticket_type: attrs[:ticket_type].presence || 'support',
          custom_attributes: attrs[:custom_attributes].presence || {}
        }
        mapped[:content] = attrs[:description] if attrs[:description].present?
        mapped[:assignee_ids] = attrs[:assignee_ids] if attrs[:assignee_ids]
        # parent_id is attacker-controllable; the same-project / one-level / cross-tenant
        # guards live in the Ticket model validations (as for the web path), not here.
        mapped[:parent_id] = attrs[:parent_id] if attrs[:parent_id].present?
        mapped
      end

      # --- Update helpers --------------------------------------------------

      def update_params
        permitted = params.require(:ticket).permit(:status, assignee_ids: [])
        # Use to_h.symbolize_keys so we can introspect with .key?
        permitted.to_h.symbolize_keys
      end

      # Maps the API update whitelist (status, assignee_ids) onto SaveTicket params.
      # status is merged into custom_attributes (preserving the other keys), as the
      # previous apply_status_change did. assignee_ids is forwarded only when the
      # client sent the key, so a status-only update leaves assignees untouched
      # while an explicit [] still clears them (SaveTicket treats [] as "remove all").
      def save_ticket_update_params(ticket)
        attrs = update_params
        mapped = {}
        mapped[:custom_attributes] = (ticket.custom_attributes || {}).merge('status' => attrs[:status].to_s) if attrs.key?(:status)
        mapped[:assignee_ids] = attrs[:assignee_ids] if attrs.key?(:assignee_ids)
        mapped
      end

      # --- Loaders ---------------------------------------------------------

      def load_project_without_tenant(id)
        raise ActiveRecord::RecordNotFound if id.blank?

        ActsAsTenant.without_tenant { Project.find(id) }
      end

      # --- Pagination (ticket list filtering/ordering lives in Tickets::Filter) --
      # page_param/per_page_param are kept here because #activities also paginates
      # (a non-ticket relation), so they are not specific to the ticket-list query.

      def page_param
        [params[:page].to_i, 1].max
      end

      def per_page_param
        raw = params[:per_page].to_i
        return DEFAULT_PER_PAGE if raw <= 0

        [raw, MAX_PER_PAGE].min
      end

      # --- Serialization --------------------------------------------------

      # Shared ticket JSON shape, extracted to Tickets::Serializer so the API and
      # the MCP read tools cannot drift (D4). The web-only `permissions` block and
      # signed attachment URLs stay here in the controller.
      def ticket_serializer
        @ticket_serializer ||= Tickets::Serializer.new(current_user: current_user)
      end

      def serialize_permissions(ticket)
        project = ticket.project
        project_policy = ProjectPolicy.new(current_user, project)
        time_perm = current_user.time_session_permissions.backed_by_project_access.find_by(project: project)
        admin = current_user.account_admin_in?(project.organisation)

        {
          is_account_admin: admin,
          tickets: {
            read: project_policy.area_access?(:tickets, :read) || admin,
            write: project_policy.area_access?(:tickets, :write) || admin
          },
          documents: {
            read: project_policy.area_access?(:documents, :read) || admin,
            write: project_policy.area_access?(:documents, :write) || admin
          },
          posts: {
            can_create: project_policy.area_access?(:tickets, :write) || admin,
            can_update_own: project_policy.area_access?(:tickets, :write) || admin,
            can_destroy_own: project_policy.area_access?(:tickets, :write) || admin
          },
          time_sessions: serialize_time_session_permissions(time_perm, admin),
          activities: { read: project_policy.view_activities? || admin }
        }
      end

      def paginate(relation)
        page = page_param
        per = per_page_param
        total = relation.count
        paged = relation.limit(per).offset((page - 1) * per).to_a
        [paged, total]
      end

      def pagination_meta(total)
        { page: page_param, per_page: per_page_param, total: total }
      end

      def serialize_activity(activity)
        {
          id: activity.id,
          key: activity.key,
          action: activity.action,
          actor: { id: activity.actor_id, name: activity.actor&.display_name },
          parameters: activity.parameters,
          attribute_changes: activity.attribute_changes,
          created_at: activity.created_at.iso8601
        }
      end

      def collect_attachments(ticket)
        documents = []

        # Direct ticket attachments via TicketDocument.
        ticket.ticket_documents.includes(ticket_document_file_attachment: :blob).find_each do |td|
          blob = td.ticket_document_file&.blob
          next unless blob

          documents << build_attachment(blob, td.ticket_document_file, attached_to: 'ticket')
        end

        # Comment attachments via PostDocument, the same rows Tickets::Serializer
        # counts as attachments_count. This used to read post.attachments, the
        # has_many_attached NOTHING in the app writes, so the list answered "none" for
        # every comment that had a file while #show reported a real count — one API,
        # two answers to the same question. Preloaded, because one read per
        # readable comment was an N+1; sorted by id as find_each used to order them.
        ticket.posts.readable_by(current_user, ticket.organisation)
              .includes(post_documents: { post_document_file_attachment: :blob }).find_each do |post|
          post.post_documents.sort_by(&:id).each do |pd|
            blob = pd.post_document_file&.blob
            next unless blob

            documents << build_attachment(blob, pd.post_document_file, attached_to: 'post', parent_id: post.id)
          end
        end

        documents
      end

      def build_attachment(blob, attachment_proxy, attached_to:, parent_id: nil)
        {
          id: attachment_proxy.id,
          filename: blob.filename.to_s,
          content_type: blob.content_type,
          byte_size: blob.byte_size,
          attached_to: attached_to,
          parent_id: parent_id,
          # service_url is a directly-signed URL (no Rails redirect),
          # so that the API client can access it without a browser session.
          url: blob.url(expires_in: 5.minutes),
          created_at: blob.created_at.iso8601
        }
      end

      def serialize_time_session_permissions(perm, admin)
        if admin
          {
            can_view_own: true, can_view_all: true,
            can_create_own: true,
            can_edit_own: true, can_edit_all: true,
            can_delete_own: true, can_delete_all: true
          }
        elsif perm
          {
            can_view_own: perm.can_view_own?, can_view_all: perm.can_view_all?,
            can_create_own: perm.can_create_own?,
            can_edit_own: perm.can_edit_own?, can_edit_all: perm.can_edit_all?,
            can_delete_own: perm.can_delete_own?, can_delete_all: perm.can_delete_all?
          }
        else
          {
            can_view_own: false, can_view_all: false,
            can_create_own: false,
            can_edit_own: false, can_edit_all: false,
            can_delete_own: false, can_delete_all: false
          }
        end
      end
    end
  end
end
