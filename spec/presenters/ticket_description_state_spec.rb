# frozen_string_literal: true

require 'rails_helper'

# Specs for TicketDescriptionState — the view-model behind the collapsible
# ticket description in the detail view.
#
# WHAT THIS GUARDS
# The three user-visible decisions (collapse / show info box / changed badge)
# and how they hang together. These are the contract the header partial and the
# Stimulus controller render against, so the truth table below is load-bearing.
#
# WHY THE EXAMPLES LOOK THE WAY THEY DO
#   - "known ticket" is driven purely by the viewer having their OWN post on the
#     ticket; every collapse example therefore creates (or omits) a post by the
#     viewing user, not by someone else;
#   - the change badge compares two timestamps, so those examples use travel_to
#     to make the ordering deterministic instead of relying on sub-millisecond
#     insert order;
#   - the unknown-value and nil-user examples kill mutants that a happy-path
#     pair alone would let survive.
RSpec.describe TicketDescriptionState do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:ticket) do
    create(:ticket, project: project, organisation: organisation, creator: user, content: 'Some description')
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def own_comment!
    create(:post, ticket: ticket, user: user, organisation: organisation)
  end

  describe '#collapsed?' do
    it 'does not collapse when the user has never commented (unknown ticket)' do
      expect(described_class.new(ticket: ticket, current_user: user).collapsed?).to be false
    end

    context 'when the user has commented (known ticket)' do
      before { own_comment! }

      it 'collapses with the default (unset) preference' do
        expect(described_class.new(ticket: ticket, current_user: user).collapsed?).to be true
      end

      it 'collapses with the explicit auto preference' do
        user.preference_store.set('description_collapse', 'auto')
        expect(described_class.new(ticket: ticket, current_user: user).collapsed?).to be true
      end

      it 'does not collapse with the always_full preference' do
        user.preference_store.set('description_collapse', 'always_full')
        expect(described_class.new(ticket: ticket, current_user: user).collapsed?).to be false
      end

      it 'does not collapse when the ticket has no description (nothing to hide)' do
        blank = create(:ticket, project: project, organisation: organisation, creator: user, content: '')
        create(:post, ticket: blank, user: user, organisation: organisation)
        expect(described_class.new(ticket: blank, current_user: user).collapsed?).to be false
      end
    end

    it "ignores other users' comments (only the viewer's own count as known)" do
      other = create(:user)
      create(:post, ticket: ticket, user: other, organisation: organisation)
      expect(described_class.new(ticket: ticket, current_user: user).collapsed?).to be false
    end
  end

  describe '#collapsible?' do
    it 'is false on an unknown ticket (no own comment)' do
      expect(described_class.new(ticket: ticket, current_user: user).collapsible?).to be false
    end

    it 'is true once the user has commented and the ticket has a description' do
      own_comment!
      expect(described_class.new(ticket: ticket, current_user: user).collapsible?).to be true
    end

    it 'is true even with always_full (the toggle still renders, just expanded)' do
      own_comment!
      user.preference_store.set('description_collapse', 'always_full')
      state = described_class.new(ticket: ticket, current_user: user)
      expect(state.collapsible?).to be true
      expect(state.collapsed?).to be false
    end
  end

  describe '#show_infobox?' do
    context 'when the user has commented (known ticket)' do
      before { own_comment! }

      it 'shows while collapsing and unanswered (default)' do
        expect(described_class.new(ticket: ticket, current_user: user).show_infobox?).to be true
      end

      it 'hides once the user answered with auto' do
        user.preference_store.set('description_collapse', 'auto')
        expect(described_class.new(ticket: ticket, current_user: user).show_infobox?).to be false
      end

      it 'hides when not collapsing at all (always_full)' do
        user.preference_store.set('description_collapse', 'always_full')
        expect(described_class.new(ticket: ticket, current_user: user).show_infobox?).to be false
      end
    end

    it 'never shows on an unknown ticket (nothing got collapsed to explain)' do
      expect(described_class.new(ticket: ticket, current_user: user).show_infobox?).to be false
    end
  end

  describe '#description_changed?' do
    before { user.preference_store.set('description_collapse', 'auto') } # ensure collapsed

    it 'is true when the description was edited after the user last commented' do
      travel_to(Time.zone.local(2026, 6, 1, 10, 0, 0)) { ticket } # create with content at 10:00
      travel_to(Time.zone.local(2026, 6, 1, 11, 0, 0)) { own_comment! } # last own post 11:00
      travel_to(Time.zone.local(2026, 6, 1, 12, 0, 0)) { ticket.update!(content: 'edited later') }

      state = described_class.new(ticket: ticket.reload, current_user: user)
      expect(state.description_changed?).to be true
    end

    it 'is false when the user commented after the last description edit' do
      travel_to(Time.zone.local(2026, 6, 1, 10, 0, 0)) { ticket } # content at 10:00
      travel_to(Time.zone.local(2026, 6, 1, 11, 0, 0)) { own_comment! } # post at 11:00, no later edit

      state = described_class.new(ticket: ticket.reload, current_user: user)
      expect(state.description_changed?).to be false
    end

    it 'is false when the description is not collapsed (always_full), even after an edit' do
      user.preference_store.set('description_collapse', 'always_full')
      travel_to(Time.zone.local(2026, 6, 1, 10, 0, 0)) { ticket }
      travel_to(Time.zone.local(2026, 6, 1, 11, 0, 0)) { own_comment! }
      travel_to(Time.zone.local(2026, 6, 1, 12, 0, 0)) { ticket.update!(content: 'edited later') }

      state = described_class.new(ticket: ticket.reload, current_user: user)
      expect(state.description_changed?).to be false
    end
  end

  # Foundation for the change badge: it has NO schema support and reads
  # ticket.rich_text_content.updated_at as a content-only timestamp. That only
  # holds if non-content edits leave the rich_text record untouched (ActionText
  # autosaves the body only when it actually changed). If either example below
  # breaks, description_changed? would fire on every status/assignee/title edit
  # and the §4 fallback (explicit content tracking) is required.
  describe 'rich_text_content.updated_at isolation (badge foundation)' do
    it 'does not bump when a non-content attribute (title) changes' do
      travel_to(Time.zone.local(2026, 6, 1, 10, 0, 0)) { ticket }
      before_ts = ticket.rich_text_content.updated_at

      travel_to(Time.zone.local(2026, 6, 1, 12, 0, 0)) { ticket.update!(title: 'Renamed, body untouched') }

      expect(ticket.reload.rich_text_content.updated_at).to be_within(1.second).of(before_ts)
    end

    it 'bumps when the description body changes' do
      travel_to(Time.zone.local(2026, 6, 1, 10, 0, 0)) { ticket }
      before_ts = ticket.rich_text_content.updated_at

      travel_to(Time.zone.local(2026, 6, 1, 12, 0, 0)) { ticket.update!(content: 'Changed body') }

      expect(ticket.reload.rich_text_content.updated_at).to be > before_ts
    end
  end

  describe 'without a current_user' do
    before { own_comment! }

    it 'is fully inert (no collapse, no info box, no badge)' do
      state = described_class.new(ticket: ticket, current_user: nil)
      expect(state.collapsed?).to be false
      expect(state.show_infobox?).to be false
      expect(state.description_changed?).to be false
    end
  end
end
