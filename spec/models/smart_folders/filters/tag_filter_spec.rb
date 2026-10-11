# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolders::Filters::TagFilter, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  let(:smart_folder) do
    create(:smart_folder, organisation: organisation, user: user, project: project,
                          target_object_type: 'Ticket')
  end
  let(:rule_group) { create(:smart_folder_rule_group, smart_folder: smart_folder) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  # -- Helpers ---------------------------------------------------------------

  def build_rule(operator:, value:)
    create(:smart_folder_rule,
           smart_folder_rule_group: rule_group,
           field: 'tag', operator: operator, value: value)
  end

  def apply_filter(rule, query: Ticket.where(project: project), item_type: 'Ticket')
    described_class.new(rule).apply(query, item_type)
  end

  # Creates tags and tickets in a batch to avoid N+1 false positives.
  # Prosopite is paused during the setup phase, since repeated INSERTs
  # from ticket callbacks (activities, subscriptions) are structurally identical.
  def create_tagged_ticket(*tag_names)
    ticket = create(:ticket, project: project)
    tag_names.each do |name|
      tag = Tag.find_or_create_by!(name: name, organisation: organisation)
      create(:tagging, tag: tag, taggable: ticket)
    end
    ticket
  end

  # -- Test data -------------------------------------------------------------

  # Pause Prosopite: ticket factory callbacks produce structurally
  # identical queries (activities, subscriptions, etc.) per ticket
  let!(:ticket_bug) do
    Prosopite.pause { create_tagged_ticket('bug') }
  end
  let!(:ticket_feature) do
    Prosopite.pause { create_tagged_ticket('feature') }
  end
  let!(:ticket_bug_and_urgent) do
    Prosopite.pause { create_tagged_ticket('bug', 'urgent') }
  end
  let!(:ticket_untagged) do
    Prosopite.pause { create(:ticket, project: project) }
  end

  # ==========================================================================
  # Operator: has / has_any_of
  # ==========================================================================

  describe "operator 'has'" do
    it 'returns tickets with the specified tag' do
      rule = build_rule(operator: 'has', value: 'bug')
      result = apply_filter(rule)

      expect(result).to contain_exactly(ticket_bug, ticket_bug_and_urgent)
    end

    it 'excludes untagged tickets' do
      rule = build_rule(operator: 'has', value: 'bug')
      result = apply_filter(rule)

      expect(result).not_to include(ticket_untagged)
    end

    it 'excludes tickets with different tags' do
      rule = build_rule(operator: 'has', value: 'bug')
      result = apply_filter(rule)

      expect(result).not_to include(ticket_feature)
    end
  end

  describe "operator 'has_any_of'" do
    it 'returns tickets matching any of the specified tags' do
      rule = build_rule(operator: 'has_any_of', value: 'bug, feature')
      result = apply_filter(rule)

      expect(result).to contain_exactly(ticket_bug, ticket_feature, ticket_bug_and_urgent)
    end

    it 'excludes untagged tickets' do
      rule = build_rule(operator: 'has_any_of', value: 'bug, feature')
      result = apply_filter(rule)

      expect(result).not_to include(ticket_untagged)
    end

    it 'does not return duplicates when ticket has multiple matching tags' do
      rule = build_rule(operator: 'has_any_of', value: 'bug, urgent')
      result_ids = apply_filter(rule).pluck(:id)

      expect(result_ids).to match_array(result_ids.uniq)
      expect(result_ids).to contain_exactly(ticket_bug.id, ticket_bug_and_urgent.id)
    end
  end

  # ==========================================================================
  # Operator: not_has
  # ==========================================================================

  describe "operator 'not_has'" do
    it 'returns tickets without the specified tag' do
      rule = build_rule(operator: 'not_has', value: 'bug')
      result = apply_filter(rule)

      expect(result).to contain_exactly(ticket_feature, ticket_untagged)
    end

    it 'includes untagged tickets' do
      rule = build_rule(operator: 'not_has', value: 'bug')
      result = apply_filter(rule)

      expect(result).to include(ticket_untagged)
    end

    it 'excludes tickets that have the tag (even with additional tags)' do
      rule = build_rule(operator: 'not_has', value: 'bug')
      result = apply_filter(rule)

      expect(result).not_to include(ticket_bug_and_urgent)
    end

    it 'handles multiple tags (excludes tickets with any of them)' do
      rule = build_rule(operator: 'not_has', value: 'bug, feature')
      result = apply_filter(rule)

      expect(result).to contain_exactly(ticket_untagged)
    end
  end

  # ==========================================================================
  # Operator: has_all_of
  # ==========================================================================

  describe "operator 'has_all_of'" do
    it 'returns only tickets with ALL specified tags' do
      rule = build_rule(operator: 'has_all_of', value: 'bug, urgent')
      result = apply_filter(rule)

      expect(result).to contain_exactly(ticket_bug_and_urgent)
    end

    it 'excludes tickets missing one of the required tags' do
      rule = build_rule(operator: 'has_all_of', value: 'bug, urgent')
      result = apply_filter(rule)

      expect(result).not_to include(ticket_bug)
    end

    it 'works with a single tag (same as has)' do
      rule = build_rule(operator: 'has_all_of', value: 'bug')
      result = apply_filter(rule)

      expect(result).to contain_exactly(ticket_bug, ticket_bug_and_urgent)
    end

    it 'returns none when no ticket has all tags' do
      rule = build_rule(operator: 'has_all_of', value: 'bug, feature, urgent')
      result = apply_filter(rule)

      expect(result).to be_empty
    end
  end

  # ==========================================================================
  # Edge cases: empty / invalid values
  # ==========================================================================

  describe 'empty tag values' do
    context 'with blank value (bypassing validation)' do
      # SmartFolderRule has value_required: true for the tag field,
      # so we bypass the validation with update_column
      def build_rule_with_blank_value(operator:)
        rule = build_rule(operator: operator, value: 'placeholder')
        rule.update_column(:value, '')
        rule.reload
      end

      it "returns none for 'has'" do
        rule = build_rule_with_blank_value(operator: 'has')
        result = apply_filter(rule)

        expect(result).to be_empty
      end

      it "returns none for 'has_any_of'" do
        rule = build_rule_with_blank_value(operator: 'has_any_of')
        result = apply_filter(rule)

        expect(result).to be_empty
      end

      it "returns none for 'has_all_of'" do
        rule = build_rule_with_blank_value(operator: 'has_all_of')
        result = apply_filter(rule)

        expect(result).to be_empty
      end

      it "returns all for 'not_has'" do
        rule = build_rule_with_blank_value(operator: 'not_has')
        result = apply_filter(rule)

        expect(result.count).to eq(4)
      end
    end

    context 'with nil value (bypassing validation)' do
      it "returns none for 'has'" do
        rule = build_rule(operator: 'has', value: 'placeholder')
        rule.update_column(:value, nil)
        rule.reload

        result = apply_filter(rule)
        expect(result).to be_empty
      end

      it "returns all for 'not_has'" do
        rule = build_rule(operator: 'not_has', value: 'placeholder')
        rule.update_column(:value, nil)
        rule.reload

        result = apply_filter(rule)
        expect(result.count).to eq(4)
      end
    end

    context 'with whitespace-only and empty segments' do
      it 'ignores blank segments in comma-separated values' do
        rule = build_rule(operator: 'has', value: ' , bug , , ')
        result = apply_filter(rule)

        expect(result).to contain_exactly(ticket_bug, ticket_bug_and_urgent)
      end
    end

    context 'with duplicate tag names' do
      it 'deduplicates and returns correct results' do
        rule = build_rule(operator: 'has_any_of', value: 'bug, bug, bug')
        result = apply_filter(rule)

        expect(result).to contain_exactly(ticket_bug, ticket_bug_and_urgent)
      end
    end
  end

  # ==========================================================================
  # Edge cases: non-existent tags
  # ==========================================================================

  describe 'non-existent tags' do
    it "returns none for 'has' with a non-existent tag" do
      rule = build_rule(operator: 'has', value: 'nonexistent_tag')
      result = apply_filter(rule)

      expect(result).to be_empty
    end

    it "returns all for 'not_has' with a non-existent tag" do
      rule = build_rule(operator: 'not_has', value: 'nonexistent_tag')
      result = apply_filter(rule)

      expect(result.count).to eq(4)
    end

    it "returns none for 'has_all_of' when one tag doesn't exist" do
      rule = build_rule(operator: 'has_all_of', value: 'bug, nonexistent_tag')
      result = apply_filter(rule)

      expect(result).to be_empty
    end

    it "returns matching for 'has_any_of' with mix of existing and non-existing" do
      rule = build_rule(operator: 'has_any_of', value: 'bug, nonexistent_tag')
      result = apply_filter(rule)

      expect(result).to contain_exactly(ticket_bug, ticket_bug_and_urgent)
    end
  end

  # ==========================================================================
  # Edge cases: tenant isolation
  # ==========================================================================

  describe 'tenant isolation' do
    let(:other_org) { create(:organisation) }

    it 'does not match tags from other organisations' do
      Prosopite.pause do
        ActsAsTenant.with_tenant(other_org) do
          other_project = create(:project, organisation: other_org)
          other_ticket = create(:ticket, project: other_project)
          other_tag = Tag.create!(name: 'special_tag', organisation: other_org)
          Tagging.create!(tag: other_tag, taggable: other_ticket)
        end
      end

      rule = build_rule(operator: 'has', value: 'special_tag')
      result = apply_filter(rule)

      expect(result).to be_empty
    end

    it 'correctly filters when same tag name exists in multiple organisations' do
      tag_own = Tag.create!(name: 'shared', organisation: organisation)
      create(:tagging, tag: tag_own, taggable: ticket_untagged)

      Prosopite.pause do
        ActsAsTenant.with_tenant(other_org) do
          Tag.create!(name: 'shared', organisation: other_org)
        end
      end

      rule = build_rule(operator: 'has', value: 'shared')
      result = apply_filter(rule)

      expect(result).to contain_exactly(ticket_untagged)
    end
  end

  # ==========================================================================
  # Edge cases: non-taggable models
  # ==========================================================================

  describe 'non-taggable model' do
    it 'returns query unchanged and logs a warning' do
      rule = build_rule(operator: 'has', value: 'bug')

      allow(Rails.logger).to receive(:warn)

      user_query = User.all
      result = apply_filter(rule, query: user_query, item_type: 'User')

      expect(result).to eq(user_query)
      expect(Rails.logger).to have_received(:warn).with(/does not support tagging/)
    end
  end

  # ==========================================================================
  # Edge cases: unsupported operator
  # ==========================================================================

  describe 'unsupported operator' do
    it 'returns query unchanged and logs a warning' do
      rule = build_rule(operator: 'has', value: 'bug')
      rule.update_column(:operator, 'contains')
      rule.reload

      allow(Rails.logger).to receive(:warn)

      result = apply_filter(rule)

      expect(result.count).to eq(4)
      expect(Rails.logger).to have_received(:warn).with(/Unsupported tag operator 'contains'/)
    end
  end

  # ==========================================================================
  # Edge cases: empty table
  # ==========================================================================

  describe 'empty dataset' do
    before do
      Prosopite.pause { Ticket.where(project: project).destroy_all }
    end

    it 'returns empty relation without errors' do
      rule = build_rule(operator: 'has', value: 'bug')
      result = apply_filter(rule)

      expect(result).to be_empty
      expect(result).to be_a(ActiveRecord::Relation)
    end

    it "returns empty relation for 'not_has'" do
      rule = build_rule(operator: 'not_has', value: 'bug')
      result = apply_filter(rule)

      expect(result).to be_empty
    end
  end

  # ==========================================================================
  # Query composition
  # ==========================================================================

  describe 'query composition' do
    it 'preserves existing query scopes (project filter)' do
      other_project = create(:project, organisation: organisation)
      other_ticket = Prosopite.pause do
        t = create(:ticket, project: other_project)
        tag = Tag.find_or_create_by!(name: 'bug', organisation: organisation)
        create(:tagging, tag: tag, taggable: t)
        t
      end

      rule = build_rule(operator: 'has', value: 'bug')
      result = apply_filter(rule, query: Ticket.where(project: project))

      expect(result).to contain_exactly(ticket_bug, ticket_bug_and_urgent)
      expect(result).not_to include(other_ticket)
    end

    it 'returns ActiveRecord::Relation (chainable)' do
      rule = build_rule(operator: 'has', value: 'bug')
      result = apply_filter(rule)

      expect(result).to be_a(ActiveRecord::Relation)
      expect { result.order(:created_at).limit(1).to_a }.not_to raise_error
    end
  end

  # ==========================================================================
  # parse_tag_names unit tests (via apply behavior)
  # ==========================================================================

  describe 'tag name parsing' do
    it 'strips whitespace from tag names' do
      rule = build_rule(operator: 'has', value: '  bug  ')
      result = apply_filter(rule)

      expect(result).to contain_exactly(ticket_bug, ticket_bug_and_urgent)
    end

    it 'handles comma-separated values with inconsistent spacing' do
      rule = build_rule(operator: 'has_any_of', value: 'bug,feature, urgent')
      result = apply_filter(rule)

      expect(result).to contain_exactly(ticket_bug, ticket_feature, ticket_bug_and_urgent)
    end
  end
end
