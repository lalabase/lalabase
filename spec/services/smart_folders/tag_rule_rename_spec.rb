# frozen_string_literal: true

require 'rails_helper'

# The tag rules of the saved filters name tags by name (TagFilter reads the value).
# A renamed or merged tag rewrites them, or a filter shows nothing from then on.
RSpec.describe SmartFolders::TagRuleRename, type: :service do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  def rule(value, org: organisation, field: 'tag', operator: SmartFolders::Operators::HAS_ANY_OF)
    ActsAsTenant.with_tenant(org) do
      folder = create(:smart_folder, organisation: org, project: create(:project, organisation: org),
                                     target_object_type: 'Ticket')
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group, field: field, operator: operator, value: value)
    end
  end

  def rename(from, to)
    described_class.call(organisation: organisation, from: from, to: to)
  end

  it 'replaces the name in every tag rule of the organisation and keeps the others' do
    several = rule('intern, kunde-a ,extern')
    single = rule('kunde-a', operator: SmartFolders::Operators::HAS)
    longer = rule('kunde-ab')
    title = rule('kunde-a', field: 'title', operator: 'contains')

    expect(rename('kunde-a', 'kunde alpha')).to eq(2)

    expect([several.reload.value, several.display_value]).to eq(['intern,kunde alpha,extern', 'intern,kunde alpha,extern'])
    expect(single.reload.value).to eq('kunde alpha')
    expect(longer.reload.value).to eq('kunde-ab')
    expect(title.reload.value).to eq('kunde-a')
  end

  it 'compares in the one spelling of tag names' do
    typed = rule('Kunde-A')

    rename('KUNDE-A ', 'Kunde Alpha')

    expect(typed.reload.value).to eq('kunde alpha')
  end

  it 'keeps a name once when the rule held the new one already' do
    both = rule('kunde-a,Kunde A,intern')

    rename('kunde-a', 'kunde a')

    expect(both.reload.value).to eq('kunde a,intern')
  end

  it 'leaves the rules of another organisation alone' do
    foreign = rule('kunde-a', org: other_organisation)

    expect(rename('kunde-a', 'kunde alpha')).to eq(0)
    expect(foreign.reload.value).to eq('kunde-a')
  end

  it 'rewrites a rule that a validation of today would refuse' do
    legacy = rule('kunde-a')
    legacy.update_columns(operator: 'no_such_operator')

    rename('kunde-a', 'kunde alpha')

    expect(legacy.reload.value).to eq('kunde alpha')
  end
end
