# frozen_string_literal: true

# What: The hub's query budget (doc/ki_bereich_navigation_plan.md §3.3).
# Type: Request spec — performance contract, not behaviour.
# Why (philosophy): The rule is not "be fast", it is "the entry page of the area must
#   not cost more than any detail page under it". That inversion is exactly what the
#   obvious implementation produces: AiSyncStatusService walks every project × every
#   type in Embeddings::ContentTypes, so a hub built on it would be the most expensive
#   page in the area while claiming to be the cheap overview.
# Contract: the hub's own reads stay within budget FOR AN ORGANISATION ON A PACKAGE,
#   the cost does not grow with the corpus, the hub is cheaper than the page it
#   summarises, and neither expensive neighbour is ever touched.
#
# ⚠️ Two mistakes this file made in its first version, both found by review, both worth
# naming because they are the standard ways a budget spec turns into decoration:
#
#   1. It measured a RECONSTRUCTION of the action instead of the request. Adding a query
#      to #show left all five examples green — the one change the budget exists to catch
#      went straight through. Measured through the real request now, with the shared
#      layout cost removed by SUBTRACTING a control page rather than by rebuilding the
#      action: session, user, memberships and sidebar are paid by every page in the app,
#      so the difference between two pages of the same layout is what this page costs.
#   2. It measured an organisation with NO package, because that is what the factory
#      builds. The whole package branch — including the preload that exists to avoid the
#      N+1 in effective_jurisdiction — never ran. The normal case was the untested one.

require 'rails_helper'

RSpec.describe 'Organisations::AiOverviews query budget', type: :request do
  # The hub's OWN reads, layout excluded. Measured at 9 for an organisation on a package
  # (package + rung + the two credential rows behind the jurisdiction claim, quota used,
  # budget, buffer, the IndexHealth union, the persona count). Raising this is a
  # decision, not a fix: it means the overview got more expensive than it was, and §3.3
  # of the plan carries the reasoning for what the number may be.
  #
  # RAISED to 10 by doc/ki_zugang_umbau_plan.md §6.5 for one named read (the activation
  # line named WHO switched AI on, a row in `users`), and STILL 10 after
  # doc/ki_uebersicht_zeilenliste_plan.md (D4, D5) by a swap rather than by luck: the
  # status sentence no longer names anybody, so that row is gone; the Protokoll row now
  # says since when the trail exists, which is one MIN over `activities`. The sentence's
  # ai_available? costs nothing extra ONLY because the controller hands its preloaded
  # package to the association the gate walks (AiOverviewsController#show) — measured
  # at 13 without that, and that regression is what this number guards now.
  #
  # RAISED to 11 on 15.09.2026 for one named read: the privacy link in the status card comes
  # from the instance admin settings (LegalIdentity.current, the four legal_* rows in one
  # query, memoised per request) instead of ENV. The operator identity had to leave ENV so a
  # self-hoster can set it without server access; a process-local cache would serve a
  # changed address late in every other worker, so the read is paid, not hidden.
  budget = 11

  let(:package) { create(:ai_package, :with_tiers, active: true) }
  # WITH an activation on record, as a real organisation has one. The hub no longer
  # reads the activating user (D4), so this no longer moves the count — it stays so the
  # measured organisation is not a bare one.
  let(:organisation) do
    create(:organisation, ai_enabled: true, ai_package: package,
                          ai_activated_at: Time.current, ai_activated_by: admin)
  end
  let(:admin) { create(:user) }
  let(:admin_role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }
  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end
  # Created up front and shared by every measurement: the sidebar renders the
  # organisation's projects, so creating one BETWEEN two counts would move the layout
  # cost and be mistaken for the page getting more expensive.
  let!(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { sign_in admin }

  # Counts real statements only: SCHEMA is connection setup, CACHE is a repeat Rails
  # already answered from memory, TRANSACTION says nothing about cost.
  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION|CACHE/)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def get_hub
    get organisation_ai_overview_path(organisation)
  end

  # The control: another management page under the SAME layout with almost no data of
  # its own. Whatever the sidebar and session cost, both pages pay it, so the difference
  # is the hub. If this page ever grows heavy the difference SHRINKS and could mask hub
  # growth — that is the one thing to check before trusting a green run here.
  def get_control
    get organisation_appearance_path(organisation)
  end

  def hub_own_queries
    get_hub
    get_control # warm up both paths: first-request lookups belong to neither page
    count_queries { get_hub } - count_queries { get_control }
  end

  it "answers its four cards in at most #{budget} own queries" do
    expect(hub_own_queries).to be <= budget
  end

  # The half that actually catches an N+1. A ceiling alone passes happily on an empty
  # organisation and only breaks in production, where the content exists.
  it 'costs the same with a corpus as it does empty' do
    get_hub
    empty = count_queries { get_hub }

    ActsAsTenant.with_tenant(organisation) do
      3.times { create(:note, project: project, organisation: organisation, create_embeddings: true) }
      3.times { create(:ticket, project: project, organisation: organisation) }
    end

    expect(count_queries { get_hub }).to eq(empty)
  end

  # The plan's sentence, asserted rather than trusted: "Die Übersicht würde mehr kosten
  # als jede Detailseite darunter."
  it 'is cheaper than the detail page it summarises' do
    ActsAsTenant.with_tenant(organisation) do
      3.times { create(:note, project: project, organisation: organisation, create_embeddings: true) }
    end
    get_hub

    hub = count_queries { get_hub }
    detail = count_queries { get organisation_ai_sync_status_path(organisation) }

    expect(hub).to be < detail
  end

  # The trap named in the controller: the estimate behind #confirm_package runs four
  # aggregates and lives on a page of its own precisely so it never lands on something
  # rendered at every visit (E7 of the packages plan). Pinned as a mechanism, because a
  # later "show the cost on the hub too" would look harmless in review.
  it 'never computes the switch estimate' do
    allow(Embeddings::SwitchEstimate).to receive(:call)

    get_hub

    expect(Embeddings::SwitchEstimate).not_to have_received(:call)
  end

  # Same class of trap, the other expensive neighbour: the hub reads
  # Embeddings::IndexHealth, never the detail page's read model.
  it 'never touches the AI sync status read model' do
    allow(AiSyncStatusService).to receive(:call).and_call_original

    get_hub

    expect(AiSyncStatusService).not_to have_received(:call)
  end
end
