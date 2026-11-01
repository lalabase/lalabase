# frozen_string_literal: true

require 'rails_helper'

# Linking tickets from the ticket page (doc/ticket_relations_plan.md, revision 4, §4, §6, §7).
# The actors check no rights, this controller does: write on tickets in the project of the SHOWN
# ticket, read on the other ticket (policy_scope(Ticket), 404 otherwise). A relation to a ticket
# the user cannot read is not theirs to see, nor to remove.
#
# Answers are streams for the shown ticket only: its section, its waiting hint, the modal. No
# stream and no activity for the other ticket: its title would leave with a response or a
# broadcast that no reader check guards (plan §4, review 5).
RSpec.describe 'Organisations::Tickets::Relations', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { new_project(organisation, 'Kundenportal') }
  let(:other_project) { new_project(organisation, 'Backoffice') }
  let(:hidden_project) { new_project(organisation, 'Vorstand') }

  let(:writer) { member(tickets: { project => 'read_write', other_project => 'read_only' }) }
  let(:reader) { member(tickets: { project => 'read_only', other_project => 'read_only' }) }

  let(:ticket) { new_ticket(project, 'Checkout breaks') }
  let(:other) { new_ticket(other_project, 'Payment provider switch') }
  # A number no other ticket here carries, so its absence from a response means something.
  let(:hidden) { new_ticket(hidden_project, 'Board decision on budget', number: 4711) }

  after { ActsAsTenant.current_tenant = nil }

  def new_project(org, name)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org, name: name) }
  end

  def new_ticket(project, title, **attributes)
    Prosopite.pause do
      ActsAsTenant.with_tenant(project.organisation) { create(:ticket, project: project, title: title, **attributes) }
    end
  end

  def member(tickets:)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      tickets.each { |project, access| create(:project_permission, user: user, project: project, tickets_access: access) }
    end
    user
  end

  def link(source, target, type, delay_days: nil)
    ActsAsTenant.with_tenant(organisation) do
      TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: type, delay_days: delay_days)
    end
  end

  # Counted without a tenant: require_tenant is on, and the request resets the tenant after it.
  def relations
    ActsAsTenant.without_tenant { TicketRelation.order(:created_at).to_a }
  end

  def relation_count
    ActsAsTenant.without_tenant { TicketRelation.count }
  end

  def side_effect_counts
    ActsAsTenant.without_tenant { { activities: Activity.count, notifications: Notification.count } }
  end

  def create_path(for_ticket = ticket)
    organisation_project_ticket_relations_path(organisation, for_ticket.project, for_ticket)
  end

  def destroy_path(relation, for_ticket = ticket)
    organisation_project_ticket_relation_path(organisation, for_ticket.project, for_ticket, relation)
  end

  # The token names the modal instance the form was sent from (review of #944): a late answer
  # must reach that instance only, never a closed or a newer one.
  let(:modal_token) { 'a1b2c3d4e5f60718' }
  let(:modal_instance) { "ticket-relation-modal-#{ticket.id}-#{modal_token}" }

  def post_link(other_ticket, kind: 'blocks', delay_days: nil, format: :turbo_stream)
    params = { other_ticket_id: other_ticket&.id, kind: kind, modal_token: modal_token }
    params[:delay_days] = delay_days unless delay_days.nil?
    post create_path, params: params, as: format
  end

  describe 'POST create' do
    before { sign_in writer }

    it 'links a ticket of another project and answers with the section, the hint and a closed modal' do
      expect { post_link(other) }.to change { relation_count }.by(1)

      relation = relations.last
      expect([relation.source_ticket_id, relation.target_ticket_id, relation.relation_type]).to eq([ticket.id, other.id, 'blocks'])
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include(%(target="ticket-relations-#{ticket.id}"))
      expect(response.body).to include(%(target="ticket-waiting-#{ticket.id}"))
      # The modal instance goes, not the frame: a modal opened again meanwhile stays.
      expect(response.body).to include(%(action="remove" target="#{modal_instance}"))
      expect(response.body).not_to include(%(target="ticket-relation-modal-#{ticket.id}"))
      expect(response.body).to include('Payment provider switch')
    end

    # The seven labels read from the SHOWN ticket's side; a backwards one is stored flipped.
    {
      'blocks' => [:ticket, :other, 'blocks'],
      'blocked_by' => [:other, :ticket, 'blocks'],
      'relates_to' => [:ticket, :other, 'relates_to'],
      'duplicates' => [:ticket, :other, 'duplicates'],
      'duplicated_by' => [:other, :ticket, 'duplicates'],
      'precedes' => [:ticket, :other, 'precedes'],
      'follows' => [:other, :ticket, 'precedes']
    }.each do |kind, (source, target, type)|
      it "stores #{kind} as #{source} #{type} #{target}" do
        post_link(other, kind: kind)

        expect(response).to have_http_status(:ok)
        stored = relations.last
        ends = { ticket: ticket.id, other: other.id }
        expect([stored.source_ticket_id, stored.target_ticket_id, stored.relation_type]).to eq([ends[source], ends[target], type])
      end
    end

    it 'stores the delay for follows and precedes' do
      post_link(other, kind: 'follows', delay_days: '3')

      expect(relations.last.delay_days).to eq(3)
    end

    it 'drops a delay sent with a kind that has none, instead of refusing the relation' do
      post_link(other, kind: 'blocks', delay_days: '3')

      expect(response).to have_http_status(:ok)
      expect(relations.last.delay_days).to be_nil
    end

    it 'stores no delay for a blank field' do
      post_link(other, kind: 'precedes', delay_days: '')

      expect(relations.last.delay_days).to be_nil
    end

    context 'when the relation is refused' do
      def expect_refused(message)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.media_type).to eq('text/vnd.turbo-stream.html')
        # Only the instance that sent it: a closed modal has no such element, and nothing
        # opens again (review of #944).
        expect(response.body).to include(%(action="replace" target="#{modal_instance}"))
        expect(response.body).to include(%(id="#{modal_instance}"), %(name="modal_token" value="#{modal_token}"))
        expect(response.body).to include(CGI.escapeHTML(message))
        expect(response.body).not_to include(%(target="ticket-relations-#{ticket.id}"))
      end

      it 'shows a cycle as a message in the modal, never a 500' do
        link(ticket, other, :blocks)

        expect { post_link(other, kind: 'blocked_by') }.not_to(change { relation_count })
        expect_refused(I18n.t('services.actors.create_ticket_relation.would_create_cycle'))
      end

      it 'shows an existing relation as a message' do
        link(ticket, other, :blocks)

        expect { post_link(other, kind: 'blocks') }.not_to(change { relation_count })
        expect_refused(I18n.t('activerecord.errors.models.ticket_relation.duplicate'))
      end

      it 'shows the reverse of a symmetric relation as a message' do
        link(other, ticket, :relates_to)

        expect { post_link(other, kind: 'relates_to') }.not_to(change { relation_count })
        expect_refused(I18n.t('activerecord.errors.models.ticket_relation.reverse_exists'))
      end

      it 'shows a link to the ticket itself as a message' do
        expect { post_link(ticket) }.not_to(change { relation_count })
        expect_refused(I18n.t('activerecord.errors.models.ticket_relation.self_reference'))
      end

      it 'shows an unknown kind as a message' do
        expect { post_link(other, kind: 'parent_of') }.not_to(change { relation_count })
        expect_refused(I18n.t('services.actors.create_ticket_relation.unknown_kind'))
      end

      it 'asks for a ticket when none was picked' do
        expect { post_link(nil) }.not_to(change { relation_count })
        expect_refused(I18n.t('views.organisations.tickets.shared.relations.modal.pick_ticket'))
      end

      it 'shows a delay out of range as a message' do
        expect { post_link(other, kind: 'precedes', delay_days: (2**40).to_s) }.not_to(change { relation_count })
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'renders the modal again with what was sent' do
        link(ticket, other, :blocks)

        post_link(other, kind: 'blocked_by')

        expect(response.body).to include(%(value="#{other.id}"))
        expect(response.body).to include(CGI.escapeHTML(other.display_title))
        expect(response.body).to match(/<option selected="selected" value="blocked_by">/)
      end

      it 'keeps the delay that was sent' do
        link(ticket, other, :blocks)

        post_link(other, kind: 'follows', delay_days: '4')

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('value="4"')
      end
    end

    # Review round 2 of #944: without the token of an open instance there is nothing to fill.
    # Filling the frame would open a modal the user may have closed; the reason goes out as
    # a flash instead (a request in flight during a deploy, or a tampered token).
    it 'answers a refusal without a usable token with a flash, and opens no modal' do
      link(ticket, other, :blocks)

      post create_path, params: { other_ticket_id: other.id, kind: 'blocks', modal_token: '"><script>' }, as: :turbo_stream

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(%(action="prepend" target="flash"))
      expect(response.body).to include(CGI.escapeHTML(I18n.t('activerecord.errors.models.ticket_relation.duplicate')))
      expect(response.body).not_to include('ticket-relation-modal-', '"><script>')
    end

    it 'answers an own failure with a 500 and without the exception text' do
      failure = Actors::BaseActor::Result.new(success: false, errors: ['PG::ConnectionBad: server closed'], code: :internal_error)
      allow(Actors::CreateTicketRelation).to receive(:call).and_return(failure)

      post_link(other)

      expect(response).to have_http_status(:internal_server_error)
      expect(response.body).not_to include('PG::ConnectionBad')
    end

    it 'redirects to the ticket on the HTML path' do
      post_link(other, format: :html)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(organisation_project_tickets_path(organisation, project, ticket_id: ticket.id))
      expect(flash[:notice]).to eq(I18n.t('flash.ticket_relations.created'))
    end

    it 'writes no activity and, after the jobs, no notification' do
      # Both tickets exist first: creating a ticket writes an activity of its own.
      ticket
      other
      before = side_effect_counts

      perform_enqueued_jobs { post_link(other) }

      expect(relation_count).to eq(1)
      expect(side_effect_counts).to eq(before)
    end

    it 'answers with nothing for the other ticket: no stream, no target' do
      post_link(other)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Payment provider switch')
      expect(response.body).not_to include("ticket-relations-#{other.id}", "ticket-waiting-#{other.id}",
                                           "data-ticket-id='#{other.id}'", %(data-ticket-id="#{other.id}"))
    end

    it 'says nothing about a related ticket the user cannot read' do
      link(hidden, ticket, :blocks)

      post_link(other)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Payment provider switch')
      expect_absent(response.body, 'Board decision on budget', 'Vorstand', hidden.id, 4711)
    end
  end

  describe 'who may link' do
    # Review round 4 of #944: a bare 404 page emptied the modal frame without a reason (the
    # ticket was picked, then deleted or its read right withdrawn). Now the modal says it, in
    # the same words whether the ticket never existed, is gone or is not readable.
    def expect_unavailable
      expect(response).to have_http_status(:not_found)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include(%(action="replace" target="#{modal_instance}"))
      expect(response.body).to include(CGI.escapeHTML(I18n.t('views.organisations.tickets.shared.relations.modal.ticket_unavailable')))
    end

    it 'refuses a ticket in a project the user cannot read with a 404, in the modal' do
      sign_in writer

      expect { post_link(hidden) }.not_to(change { relation_count })
      expect_unavailable
      expect_absent(response.body, 'Board decision on budget', 'Vorstand', hidden.id, 4711)
    end

    it 'refuses a ticket of another organisation with a 404' do
      foreign_organisation = create(:organisation)
      foreign = new_ticket(new_project(foreign_organisation, 'Fremd'), 'Foreign ticket')
      sign_in writer

      expect { post_link(foreign) }.not_to(change { relation_count })
      expect_unavailable
      expect(response.body).not_to include('Foreign ticket', foreign.id)
    end

    it 'refuses a malformed id with a 404, in the modal' do
      sign_in writer

      post create_path, params: { other_ticket_id: 'not-a-uuid', kind: 'blocks', modal_token: modal_token }, as: :turbo_stream

      expect_unavailable
    end

    it 'says so when the picked ticket was deleted before the save' do
      sign_in writer
      gone = new_ticket(other_project, 'Picked, then deleted')
      gone_id = gone.id
      ActsAsTenant.with_tenant(organisation) { gone.destroy! }

      expect { post create_path, params: { other_ticket_id: gone_id, kind: 'blocks', modal_token: modal_token }, as: :turbo_stream }
        .not_to(change { relation_count })
      expect_unavailable
    end

    it 'refuses a reader of the shown ticket, and links nothing' do
      sign_in reader

      expect { post_link(other) }.not_to(change { relation_count })
      expect(response).to have_http_status(:redirect)
    end

    it 'refuses a writer in the other project who only reads the shown one' do
      writer_elsewhere = member(tickets: { project => 'read_only', other_project => 'read_write' })
      sign_in writer_elsewhere

      expect { post_link(other) }.not_to(change { relation_count })
      expect(response).to have_http_status(:redirect)
    end

    it 'lets an account admin link across every project' do
      admin = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: admin, organisation: organisation, role: create(:admin_role, organisation: organisation),
                            active: true)
      end
      sign_in admin

      expect { post_link(hidden) }.to change { relation_count }.by(1)
    end

    it 'finds the shown ticket only in the project of the URL' do
      sign_in writer
      path = organisation_project_ticket_relations_path(organisation, project, other)

      expect { post path, params: { other_ticket_id: ticket.id, kind: 'blocks' }, as: :turbo_stream }
        .not_to(change { relation_count })
      expect(response).to have_http_status(:not_found)
    end

    it 'sends a signed-out visitor to the login' do
      post_link(other, format: :html)

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'GET new' do
    let(:new_path) { new_organisation_project_ticket_relation_path(organisation, project, ticket) }

    it 'renders the modal into its frame for a writer' do
      sign_in writer

      get new_path, headers: { 'Turbo-Frame' => "ticket-relation-modal-#{ticket.id}" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(<turbo-frame id="ticket-relation-modal-#{ticket.id}"))
      token = response.body[/name="modal_token" value="(\h{16})"/, 1]
      expect(token).to be_present
      expect(response.body).to include(%(id="ticket-relation-modal-#{ticket.id}-#{token}"))
      expect(response.body).to include(%(action="#{create_path}"))
      TicketRelation::KINDS.each_key { |kind| expect(response.body).to include(%(value="#{kind}")) }
      expect(response.body).to include(organisation_ticket_lookups_path(organisation, exclude: ticket.id).gsub('&', '&amp;'))
    end

    it 'refuses a reader' do
      sign_in reader

      get new_path

      expect(response).to have_http_status(:redirect)
    end
  end

  describe 'DELETE destroy' do
    let!(:outgoing) { link(ticket, other, :blocks) }
    let!(:incoming) { link(new_ticket(other_project, 'Other side'), ticket, :relates_to) }

    it 'removes a relation from the source side, and only that one' do
      sign_in writer

      expect { delete destroy_path(outgoing), as: :turbo_stream }.to change { relation_count }.by(-1)
      expect(relations.map(&:id)).to eq([incoming.id])
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(target="ticket-relations-#{ticket.id}"), %(target="ticket-waiting-#{ticket.id}"))
    end

    it 'removes a relation from the target side' do
      sign_in writer

      expect { delete destroy_path(incoming), as: :turbo_stream }.to change { relation_count }.by(-1)
      expect(relations.map(&:id)).to eq([outgoing.id])
    end

    it 'removes it from the other ticket page as well, when the user may write there' do
      other_writer = member(tickets: { project => 'read_only', other_project => 'read_write' })
      sign_in other_writer

      expect { delete destroy_path(outgoing, other), as: :turbo_stream }.to change { relation_count }.by(-1)
    end

    # Review round 4 of #944: a bare 404 page inside the ticket frame left "Content missing"
    # where the ticket was. The answer is the section as it is now plus the reason, the same
    # for "never existed", "not visible" and "already gone".
    def expect_gone
      expect(response).to have_http_status(:not_found)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include(%(target="ticket-relations-#{ticket.id}"), %(target="flash"))
      expect(response.body).to include(CGI.escapeHTML(I18n.t('services.actors.destroy_ticket_relation.not_found')))
    end

    it 'refuses a relation that does not touch the shown ticket with a 404 and the section' do
      stranger = link(other, new_ticket(other_project, 'Unrelated'), :relates_to)
      sign_in writer

      expect { delete destroy_path(stranger), as: :turbo_stream }.not_to(change { relation_count })
      expect_gone
      expect(response.body).not_to include('Unrelated')
    end

    it 'refuses a relation to a ticket the user cannot read with a 404, and names nothing of it' do
      invisible = link(hidden, ticket, :blocks)
      sign_in writer

      expect { delete destroy_path(invisible), as: :turbo_stream }.not_to(change { relation_count })
      expect_gone
      # The section is in the answer, with the visible relations, and still without the hidden one.
      expect(response.body).to include('Payment provider switch')
      expect_absent(response.body, 'Board decision on budget', 'Vorstand', hidden.id, 4711)
    end

    # Two people on the same ticket: A removes a relation, B's page still shows it (no
    # broadcast, on purpose) and B clicks its X.
    it 'answers a stale page with the section as it is now' do
      sign_in writer
      ActsAsTenant.with_tenant(organisation) do
        Actors::DestroyTicketRelation.call(ticket: ticket, relation: outgoing, current_user: writer)
      end

      delete destroy_path(outgoing), as: :turbo_stream

      expect_gone
      section = response.body[%r{<section id="ticket-relations-#{ticket.id}".*?</section>}m]
      expect(section).to include('Other side')
      expect(section).not_to include('Payment provider switch')
    end

    it 'refuses a reader, and removes nothing' do
      sign_in reader

      expect { delete destroy_path(outgoing), as: :turbo_stream }.not_to(change { relation_count })
      expect(response).to have_http_status(:redirect)
    end

    it 'redirects to the ticket on the HTML path' do
      sign_in writer

      delete destroy_path(outgoing)

      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq(I18n.t('flash.ticket_relations.removed'))
    end

    it 'writes no activity and, after the jobs, no notification' do
      sign_in writer
      before = side_effect_counts

      perform_enqueued_jobs { delete destroy_path(outgoing), as: :turbo_stream }

      expect(relation_count).to eq(1)
      expect(side_effect_counts).to eq(before)
    end
  end

  # Plan §8.2 (review 4): the section and the hint are containers that stay in the page, so the
  # FIRST relation has a target to replace, and the last one leaves an empty one behind.
  describe 'first, last, first again' do
    before { sign_in writer }

    def section_html
      response.body[%r{<section id="ticket-relations-#{ticket.id}".*?</section>}m]
    end

    it 'shows the section with the first relation, hides it with the last, and shows it again' do
      post_link(other, kind: 'blocked_by')
      expect(section_html).to include('Payment provider switch')
      expect(response.body).to include(%(id="ticket-waiting-#{ticket.id}"))

      delete destroy_path(relations.last), as: :turbo_stream
      expect(response).to have_http_status(:ok)
      expect(section_html).to be_present
      expect(section_html).not_to include('Payment provider switch')
      expect(response.body).to include(%(id="ticket-waiting-#{ticket.id}"))

      post_link(other, kind: 'blocked_by')
      expect(response).to have_http_status(:ok)
      expect(section_html).to include('Payment provider switch')
    end
  end
end
