# frozen_string_literal: true

# Actors::SeedOnboarding builds the "Lalabase kennenlernen" tutorial project on
# self-registration (doc/onboarding_plan.md, S1). These specs pin the three
# load-bearing decisions:
# - D11b split: CONTENT belongs to the new user (creator → correct
#   auto-subscriptions), only the ASSIGNMENT activity runs as the system user
#   (a foreign actor is what makes the fanout deliver an inbox notification).
# - skip_email: seeded assignment activities must carry the flag so the
#   pipeline creates in_app-only notifications (no mail right after signup).
# - Idempotency via projects.system_kind: retries/double-submits must not
#   create a second tutorial project.
require 'rails_helper'

RSpec.describe Actors::SeedOnboarding do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user, language_preference: 'de') }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
  end

  def call_actor
    described_class.call(organisation: organisation, current_user: user)
  end

  def tutorial_project
    organisation.projects.find_by(system_kind: 'onboarding')
  end

  describe 'project and ticket creation' do
    it 'creates the marked tutorial project with the content tickets owned by the user' do
      result = call_actor

      expect(result).to be_success
      project = tutorial_project
      expect(project).to be_present
      expect(project.name).to eq('Lalabase kennenlernen')
      expect(result.resource).to eq(project)

      tickets = project.tickets.order(:number)
      expect(tickets.count).to eq(4)
      # D11b: contents belong to the USER, not the system account
      expect(tickets.pluck(:creator_id).uniq).to eq([user.id])
      expect(tickets.pluck(Arel.sql("custom_attributes->>'status'")).uniq).to eq(['new'])
      expect(tickets.first.title).to eq('Hake diese Aufgabe ab')
      assignments = TicketAssignment.where(ticket: tickets)
      expect(assignments.count).to eq(4)
      expect(assignments.pluck(:user_id).uniq).to eq([user.id])
    end

    it 'provisions the default ticket attributes (status/priority/due date)' do
      call_actor

      expect(tutorial_project.ticket_attribute_definitions.pluck(:name))
        .to include('status', 'priority')
    end

    it 'subscribes the user to the tutorial tickets (assignment subscription)' do
      call_actor

      tutorial_project.tickets.find_each do |ticket|
        expect(NotificationSubscription.where(user: user, subscribable: ticket, mode: 'follow')).to exist
      end
    end
  end

  describe 'D11b actor split on the activity trail' do
    it 'records ticket creation as the user but assignment as the system account with skip_email' do
      call_actor

      tickets = tutorial_project.tickets
      created = Activity.where(trackable: tickets, action: 'created')
      assigned = Activity.where(trackable: tickets, action: 'assigned')

      expect(created.pluck(:actor_id).uniq).to eq([user.id])
      expect(assigned.count).to eq(4)
      expect(assigned.pluck(:actor_id).uniq).to eq([User.system.id])
      expect(assigned.pluck(:secondary_type, :secondary_id).uniq).to eq([['User', user.id]])
      expect(assigned.pluck(Arel.sql("parameters->>'skip_email'")).uniq).to eq(['true'])
    end

    it 'restores Current.user after the system-actor switch' do
      call_actor
      expect(Current.user).to be_nil
    end
  end

  describe 'idempotency' do
    it 'does not create a second tutorial project or more tickets on a second call' do
      call_actor
      expect { call_actor }.not_to(change { [Project.count, Ticket.count] })
      expect(organisation.projects.where(system_kind: 'onboarding').count).to eq(1)
    end

    it 'still returns success with the existing project' do
      call_actor
      result = call_actor
      expect(result).to be_success
      expect(result.resource).to eq(tutorial_project)
    end
  end

  describe 'content locale' do
    # Positive iteration over the WHITELIST CONSTANT (not hardcoded strings):
    # if someone adds a locale to CONTENT_LOCALES without shipping the content
    # file — or ships a file without the required keys — this breaks.
    Actors::SeedOnboarding::CONTENT_LOCALES.each do |locale|
      it "has a loadable, complete content file for #{locale.inspect}" do
        path = Rails.root.join(Actors::SeedOnboarding::CONTENT_DIR, "#{locale}.yml")
        expect(File).to exist(path)

        content = YAML.safe_load_file(path)
        expect(content.dig('project', 'name')).to be_present
        expect(content['tickets']).to be_present
        content['tickets'].each do |ticket|
          expect(ticket['key']).to be_present
          expect(ticket['title']).to be_present
        end
      end

      it "seeds successfully for a #{locale.inspect} user" do
        allow(user).to receive(:language_preference).and_return(locale)
        expect(call_actor).to be_success
        expect(tutorial_project).to be_present
      end
    end

    # Structural parity: DE and EN must describe the SAME tutorial (same
    # ticket keys, same order). Catches the classic "only edited de.yml" drift
    # — v1-frozen makes later repairs of shipped content impossible.
    it 'keeps the ticket keys of all locales in sync' do
      keys_per_locale = Actors::SeedOnboarding::CONTENT_LOCALES.map do |locale|
        content = YAML.safe_load_file(Rails.root.join(Actors::SeedOnboarding::CONTENT_DIR, "#{locale}.yml"))
        content['tickets'].map { |t| t['key'] }
      end
      expect(keys_per_locale.uniq.size).to eq(1)
    end

    it 'seeds English content for an EN user' do
      user.update!(language_preference: 'en')
      call_actor
      expect(tutorial_project.name).to eq('Getting to know Lalabase')
    end

    it 'falls back to German for an unknown locale' do
      allow(user).to receive(:language_preference).and_return('fr')
      call_actor
      expect(tutorial_project.name).to eq('Lalabase kennenlernen')
    end
  end

  describe 'initial status contract (link to banner + board)' do
    # INITIAL_STATUS is the hinge between three blocks: the seed writes it,
    # the board columns group by it, and the banner's lifetime counts tickets
    # NOT in a closed status. If someone renames the default status option or
    # marks it closed, the whole chain silently degrades — this breaks first.
    it 'is an allowed, NOT-closed status value of the provisioned definition' do
      call_actor
      project = tutorial_project

      allowed = project.ticket_attribute_definitions.find_by!(name: 'status')
                       .options.fetch('allowed_values').map { |o| o['value'] }
      closed = TicketAttributeDefinition.closed_status_values_for([project.id])

      expect(allowed).to include(Actors::SeedOnboarding::INITIAL_STATUS)
      expect(closed).not_to include(Actors::SeedOnboarding::INITIAL_STATUS)
    end
  end

  describe 'tenant isolation' do
    # A tenant leak here would seed tutorial content into a FOREIGN paying
    # org. The actor must scope itself via with_tenant(@organisation) no
    # matter what the ambient tenant is when it is called.
    it 'seeds only the target organisation even when another tenant is ambient' do
      other_org = ActsAsTenant.without_tenant { create(:organisation) }

      ActsAsTenant.with_tenant(other_org) do
        # Prosopite: the per-ticket organisation lookups in the activity
        # callbacks are the bounded 4er seed loop (see allowlist) — the
        # callback boundary hides the allowlisted frame here.
        Prosopite.pause
        described_class.call(organisation: organisation, current_user: user)
        Prosopite.resume
      end

      ActsAsTenant.without_tenant do
        expect(Project.where(organisation: organisation, system_kind: 'onboarding').count).to eq(1)
        expect(Project.where(organisation: other_org).count).to eq(0)
      end
    end

    # The idempotency guard must be org-scoped: seeding org A must not
    # short-circuit seeding org B (mutation: find_by without the org scope).
    it 'seeds a second organisation independently of the first' do
      call_actor

      other_org = ActsAsTenant.without_tenant { create(:organisation) }
      other_admin_role = ActsAsTenant.with_tenant(other_org) { create(:admin_role, organisation: other_org) }
      other_user = create(:user)
      ActsAsTenant.with_tenant(other_org) do
        create(:membership, user: other_user, organisation: other_org, role: other_admin_role, active: true)
        described_class.call(organisation: other_org, current_user: other_user)
      end

      ActsAsTenant.without_tenant do
        expect(Project.where(system_kind: 'onboarding').count).to eq(2)
      end
    end
  end

  describe 'DB-level idempotency (defense in depth)' do
    # The actor's find_by guard has a TOCTOU window under double submit; the
    # partial UNIQUE index (organisation_id, system_kind) closes it at the DB
    # layer. Must stay red if someone drops the unique flag as "redundant".
    it 'rejects a second onboarding project per organisation at the DB layer' do
      call_actor
      racer = organisation.projects.build(name: 'Zweites Tutorial', system_kind: 'onboarding')
      expect { racer.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'still allows one onboarding project per organisation across different orgs' do
      call_actor
      other_org = ActsAsTenant.without_tenant { create(:organisation) }
      ActsAsTenant.with_tenant(other_org) do
        racer = other_org.projects.build(name: 'Anderes Tutorial', system_kind: 'onboarding')
        expect { racer.save!(validate: false) }.not_to raise_error
      end
    end
  end

  describe 'cleanup contract ("Projekt löschen = Onboarding rückstandsfrei weg")' do
    # The plan promises residue-free deletion. Tickets, assignments and
    # subscriptions must cascade; if someone removes a dependent: option on
    # the chain, this breaks. (Inbox notifications intentionally survive —
    # they reference the ticket polymorphically and render nil-safe; pinned
    # here so a behavior change is a conscious decision.)
    it 'cascades tickets, assignments and subscriptions on project destroy' do
      call_actor
      project = tutorial_project
      ticket_ids = project.tickets.pluck(:id)
      expect(ticket_ids).not_to be_empty

      # Prosopite: cascading destroy loads children per ticket — bounded by
      # the 4 tutorial tickets, and Project#destroy's own concern, not this
      # feature's. We assert the OUTCOME (no residue), not the query count.
      Prosopite.pause
      project.destroy!
      Prosopite.resume

      expect(Ticket.where(id: ticket_ids)).not_to exist
      expect(TicketAssignment.where(ticket_id: ticket_ids)).not_to exist
      expect(NotificationSubscription.where(subscribable_type: 'Ticket', subscribable_id: ticket_ids)).not_to exist
    end
  end
end
