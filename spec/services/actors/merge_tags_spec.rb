# frozen_string_literal: true

require 'rails_helper'

# Merging two tags in the management section "Tags": every entry of the source
# gets the target once, the source goes, and the saved filters that named it
# name the target. Never a tag into itself, never across organisations.
# Invented names only.
RSpec.describe Actors::MergeTags, type: :service do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:admin) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:source) { create(:tag, organisation: organisation, name: 'kunde-a') }
  let(:target) { create(:tag, organisation: organisation, name: 'kunde a') }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def merge(from = source, into = target)
    described_class.call(source: from, target: into, current_user: admin)
  end

  def tagged(*tags, factory: :ticket)
    entry = create(factory, project: project, organisation: organisation)
    tags.each { |tag| create(:tagging, tag: tag, taggable: entry) }
    entry
  end

  it 'gives every entry of the source the target once and deletes the source' do
    ticket = tagged(source)
    both = tagged(source, target)
    note = tagged(source, factory: :note)
    time = tagged(source, factory: :time_session)

    result = merge

    expect(result).to be_success
    expect(result.resource).to eq(target)
    expect(Tag.exists?(source.id)).to be(false)
    expect(Tagging.where(tag_id: target.id).pluck(:taggable_type, :taggable_id))
      .to contain_exactly(['Ticket', ticket.id], ['Ticket', both.id], ['Note', note.id], ['TimeSession', time.id])
  end

  it 'moves the taggings of a deleted time entry as well, so the source can go' do
    deleted = tagged(source, factory: :time_session)
    deleted.update_column(:deleted_at, Time.current)

    expect(merge).to be_success
    expect(Tagging.where(tag_id: target.id, taggable_id: deleted.id)).to exist
  end

  it 'points the saved filters at the target' do
    folder = create(:smart_folder, organisation: organisation, project: project, target_object_type: 'Ticket')
    group = create(:smart_folder_rule_group, smart_folder: folder)
    rule = create(:smart_folder_rule, smart_folder_rule_group: group, field: 'tag', operator: 'has_all_of',
                                      value: 'kunde-a,kunde a')

    merge

    expect(rule.reload.value).to eq('kunde a')
  end

  it 'refuses a tag into itself' do
    tagged(source)

    expect(merge(source, source).code).to eq(:same_tag)
    expect(Tag.exists?(source.id)).to be(true)
  end

  it 'refuses a target of another organisation and moves nothing' do
    tagged(source)
    foreign = ActsAsTenant.with_tenant(other_organisation) { create(:tag, organisation: other_organisation, name: 'kunde a') }

    expect(merge(source, foreign).code).to eq(:other_organisation)
    expect(Tagging.where(tag_id: source.id).count).to eq(1)
  end

  it 'refuses a tag deleted in the meantime as gone' do
    gone = create(:tag, organisation: organisation, name: 'weg')
    Tag.where(id: gone.id).delete_all

    expect(merge(gone, target).code).to eq(:not_found)
    expect(Tag.exists?(target.id)).to be(true)
  end

  # An entry got the target between dropping the doubles and moving the rest:
  # the unique index answers, everything rolls back, and the reader may try again.
  it 'answers a tagging added in the meantime as :concurrent_change and moves nothing' do
    tagged(source)
    allow(Tagging).to receive(:where).and_call_original
    allow(Tagging).to receive(:where).with(tag_id: source.id).and_wrap_original do |original, *args, **kwargs|
      relation = original.call(*args, **kwargs)
      allow(relation).to receive(:update_all).and_raise(ActiveRecord::RecordNotUnique)
      relation
    end

    expect(merge.code).to eq(:concurrent_change)
    expect(Tag.exists?(source.id)).to be(true)
    expect(Tagging.unscoped.where(tag_id: source.id).count).to eq(1)
  end
end
