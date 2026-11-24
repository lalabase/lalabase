# frozen_string_literal: true

require 'rails_helper'

# Renaming a tag in the management section "Tags": the one spelling of tag
# names, the rules of a typed name, never the name of another tag (that is a
# merge), and the saved filters follow in the same transaction. Invented names.
RSpec.describe Actors::RenameTag, type: :service do
  let(:organisation) { create(:organisation) }
  let(:admin) { create(:user) }
  let(:tag) { create(:tag, organisation: organisation, name: 'kunde-a') }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def rename(name, of: tag)
    described_class.call(tag: of, name: name, current_user: admin)
  end

  def tag_rule(value)
    folder = create(:smart_folder, organisation: organisation, project: create(:project, organisation: organisation),
                                   target_object_type: 'Ticket')
    group = create(:smart_folder_rule_group, smart_folder: folder)
    create(:smart_folder_rule, smart_folder_rule_group: group, field: 'tag', operator: 'has_any_of', value: value)
  end

  it 'stores the one spelling and points the saved filters at it' do
    rule = tag_rule('kunde-a')

    result = rename('  Kunde Alpha ')

    expect(result).to be_success
    expect(result.resource).to eq(tag)
    expect(tag.reload.name).to eq('kunde alpha')
    expect(rule.reload.value).to eq('kunde alpha')
  end

  it 'writes nothing for the name the tag has' do
    rule = tag_rule('Kunde-A')
    stamp = tag.updated_at

    expect(rename('KUNDE-A')).to be_success
    expect(tag.reload.updated_at).to eq(stamp)
    expect(rule.reload.value).to eq('Kunde-A')
  end

  it 'refuses the name of another tag of the organisation as :name_taken' do
    create(:tag, organisation: organisation, name: 'kunde a')

    result = rename('Kunde A')

    expect(result.code).to eq(:name_taken)
    expect(result.errors).to eq([I18n.t('services.actors.rename_tag.name_taken', name: 'kunde a')])
    expect(tag.reload.name).to eq('kunde-a')
  end

  it 'takes a name that only another organisation has' do
    other = create(:organisation)
    ActsAsTenant.with_tenant(other) { create(:tag, organisation: other, name: 'kunde alpha') }

    expect(rename('kunde alpha')).to be_success
  end

  { blank: '  ', separator: 'kunde,a', too_long: 'k' * (Tag::MAX_NAME_LENGTH + 1) }.each do |code, name|
    it "refuses a name with the problem #{code}" do
      result = rename(name)

      expect(result.code).to eq(code)
      expect(tag.reload.name).to eq('kunde-a')
    end
  end

  # Another rename took the name between the check and the write: the unique
  # index answers, and the reader gets the refusal of a taken name, not a 500.
  it 'answers a name taken in the meantime as :name_taken and keeps the rules' do
    rule = tag_rule('kunde-a')
    allow(tag).to receive(:update!).and_raise(ActiveRecord::RecordNotUnique)

    result = rename('kunde alpha')

    expect(result.code).to eq(:name_taken)
    expect(rule.reload.value).to eq('kunde-a')
  end
end
