# frozen_string_literal: true

require 'rails_helper'

# S3a T5 (assistant plan §9.3): the scope chip narrows an org-wide thread to one
# project. These are the invariants of that narrowing, and they are written
# against Tools::Scope rather than against a surface, because Scope is the ONE
# place that answers "which projects may this call touch".
#
# The rule that matters most is the second one: the chip may only ever narrow
# INSIDE the asker's rights. A stored project id is user input like any other --
# it arrives from a form, it can be stale, and it must never be able to reach
# past the gate the org-wide path already enforces.
RSpec.describe Lalabase::Tools::Scope, 'scope selection (T5)' do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
  end

  # Archiving is a timestamp (projects.archived_at), not a flag; Project.active
  # is `where(archived_at: nil)`.
  def project(name)
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation, name: name)
    end
  end

  let!(:nordlicht) { project('Nordlicht Software') }
  let!(:kundenportal) { project('Kundenportal v2') }

  def org_thread(scope_project: nil)
    ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: user, scope_project: scope_project)
    end
  end

  describe '.for' do
    # ONE factory, because the reach is resolved in two places (Tools::Runner for
    # the tool rounds, ProjectRag::Retriever for the content layer). Two hand-made
    # constructions would be two places to forget the selection -- the exact shape
    # of defect this slice's predecessors kept producing.
    it 'resolves the thread selection into the reach' do
      scope = described_class.for(chat: org_thread(scope_project: nordlicht), actor: user)

      expect(scope.project_ids(area: :tickets)).to eq([nordlicht.id])
    end

    it 'reaches every readable project when nothing is chosen' do
      scope = described_class.for(chat: org_thread, actor: user)

      expect(scope.project_ids(area: :tickets)).to match_array([nordlicht.id, kundenportal.id])
    end

    # A chip is a filter, never a key. An id that does not resolve inside this
    # organisation is no choice at all: the thread keeps the asker's own reach.
    # Note what is NOT claimed here -- it does not "fall back to all projects",
    # it falls back to all projects THE ASKER MAY READ, which is the default and
    # leaks nothing. Refusing such an id in the first place is the write path's
    # job (assistant_chats#update), tested there.
    it 'does not honour a project id that does not resolve in this organisation' do
      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
      chat = org_thread
      chat.update_column(:scope_project_id, foreign.id)

      scope = described_class.for(chat: chat, actor: user)

      expect(scope.selection).to be_nil
      expect(scope.project_ids(area: :tickets)).to match_array([nordlicht.id, kundenportal.id])
    end

    # ... and the narrowing itself can never reach past the rights, because it is
    # an intersection with them. Two gates, deliberately not the same one:
    # #selection asks whether the CHOICE still holds (may this asker pick this
    # project at all), the intersection asks what may be read INSIDE it, per area.
    # Written with a member who may see the project but not its tickets, because
    # a member with no rights at all would pass this example for the wrong reason
    # -- their reach is empty either way, and the intersection would never be
    # exercised.
    it 'narrows by intersection: the choice holds, the area gate still decides' do
      plain = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: plain, organisation: organisation,
                            role: create(:role, organisation: organisation, title: "Plain #{SecureRandom.hex(3)}"),
                            active: true)
        create(:project_permission, user: plain, project: nordlicht, notes_access: 'read_only')
      end

      scope = described_class.for(chat: org_thread(scope_project: nordlicht), actor: plain)

      expect(scope.selection).to eq(nordlicht)
      expect(scope.project_ids(area: :tickets)).to be_empty
      expect(scope.project_ids(area: :notes)).to eq([nordlicht.id])
    end

    # Archived projects are out of reach by decision (T3, confirmed for T5). A
    # thread pinned to a project that has since been archived must therefore
    # widen back rather than answer out of an empty reach -- and #selection makes
    # that visible, so the chip can say so instead of claiming a narrowing that
    # no longer holds.
    it 'widens back when the chosen project has been archived' do
      chat = org_thread(scope_project: nordlicht)
      nordlicht.update!(archived_at: Time.current)

      scope = described_class.for(chat: chat, actor: user)

      expect(scope.project_ids(area: :tickets)).to eq([kundenportal.id])
      expect(scope.selection).to be_nil
    end

    # The write path checks the rights ONCE, when the id is stored. Rights change
    # afterwards, and then the stored id names a project this asker may no longer
    # see. That is not a narrowing any more, it is a stale one: without this the
    # name travels into the system prompt (assistant_scope_hint) and into the
    # coverage sentence, while the reach intersects down to nothing and the chip
    # -- whose option list IS policy-scoped -- shows "Alle Projekte". Three
    # surfaces, three different stories about the same thread.
    it 'is no selection any more once the asker may not read the project' do
      plain = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: plain, organisation: organisation,
                            role: create(:role, organisation: organisation, title: "Plain #{SecureRandom.hex(3)}"),
                            active: true)
      end

      scope = described_class.for(chat: org_thread(scope_project: nordlicht), actor: plain)

      expect(scope.selection).to be_nil
      # ... and the name is therefore nowhere in what the answer carries.
      expect(scope.coverage(area: :tickets)).not_to have_key(:chosen)
    end

    it 'reports the selection when it still holds' do
      scope = described_class.for(chat: org_thread(scope_project: nordlicht), actor: user)

      expect(scope.selection).to eq(nordlicht)
    end

    # Was: "stays nil for a project thread (the single-project path is untouched)".
    # projekt_chat_abbau removed that kind of thread, so .for always builds a Scope now.
    # The nil case that IS left is the one that matters: no actor, no reach.
    it 'stays nil without a chat' do
      expect(described_class.for(chat: nil, actor: user)).to be_nil
    end

    # An actor-less Scope IS built (the MCP and job paths hand one in), and it is
    # fail-closed rather than nil: every reach resolves empty.
    it 'builds a Scope without an actor, whose reach is empty' do
      scope = described_class.for(chat: org_thread, actor: nil)

      expect(scope).to be_a(described_class)
      expect(scope.project_ids(area: :tickets)).to be_empty
    end
  end

  describe '#coverage' do
    # The L7 contract grows one key. `chosen` is what tells a narrowing the user
    # ASKED for apart from one their rights imposed -- the answer renders a
    # different sentence for each, and it has to be able to tell them apart a week
    # later, in a comment, far away from the chip.
    it 'names the chosen project' do
      scope = described_class.for(chat: org_thread(scope_project: nordlicht), actor: user)

      expect(scope.coverage(area: :tickets))
        .to eq(searched: 1, total: 2, chosen: 'Nordlicht Software')
    end

    it 'carries no chosen key without a selection' do
      scope = described_class.for(chat: org_thread, actor: user)

      expect(scope.coverage(area: :tickets)).to eq(searched: 2, total: 2)
    end
  end
end
