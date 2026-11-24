# frozen_string_literal: true

require 'rails_helper'

# The management section "Tags" (Organisations::TagsController, user 2026-11-24):
# the organisation's tags with the entries each hangs on, renaming, merging and
# deleting. What this file pins:
#
#   - the gate is ACCOUNT ADMIN for every page and every write. A member, the
#     creator of a tag included, changes nothing and reads no tag name here; the
#     old pages let the creator rename and delete, and their JSON list was a
#     second way to read the names.
#   - a tag of another organisation is not found, also for an admin.
#   - the counts per kind: a deleted time entry keeps its taggings and is
#     counted nowhere, as it is shown nowhere.
#   - renaming and merging rewrite the tag rules of the saved filters, in this
#     organisation only: a rule names a tag by its name, and a filter would show
#     nothing after the change without it.
#   - deleting leaves the rules: a filter on a deleted tag finds nothing, which
#     is what the tag's entries are now.
RSpec.describe 'Organisations::Tags, the management section', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation, title: 'Standard User', is_default: true) }

  let(:admin) { create(:user) }
  let(:member) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
      create(:membership, user: member, organisation: organisation, role: member_role, active: true)
      create(:project_permission, user: member, project: project, tickets_access: 'read_write')
    end
    ActsAsTenant.current_tenant = organisation
  end

  after { ActsAsTenant.current_tenant = nil }

  def tag!(name, org: organisation, creator: nil)
    ActsAsTenant.with_tenant(org) { create(:tag, name: name, organisation: org, user_id: creator&.id) }
  end

  def ticket_with(*tags)
    ActsAsTenant.with_tenant(organisation) do
      ticket = create(:ticket, project: project, organisation: organisation)
      tags.each { |tag| create(:tagging, tag: tag, taggable: ticket) }
      ticket
    end
  end

  def tagged(factory, tag)
    ActsAsTenant.with_tenant(organisation) do
      entry = create(factory, project: project, organisation: organisation)
      create(:tagging, tag: tag, taggable: entry)
      entry
    end
  end

  # A saved filter of `org` with one tag rule.
  def tag_rule(value, operator: SmartFolders::Operators::HAS_ANY_OF, org: organisation)
    ActsAsTenant.with_tenant(org) do
      folder_project = org == organisation ? project : create(:project, organisation: org)
      folder = create(:smart_folder, organisation: org, project: folder_project, user: admin, target_object_type: 'Ticket')
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'tag', operator: operator, value: value)
    end
  end

  def page_of(response)
    Nokogiri::HTML(response.body)
  end

  describe 'who may' do
    it 'refuses a member every page and every write, the creator of the tag included' do
      tag = tag!('kunde-a', creator: member)
      target = tag!('kunde a')
      ticket_with(tag)
      sign_in member

      get organisation_tags_path(organisation)
      expect(response).to redirect_to(root_path)
      get organisation_tags_path(organisation, format: :json)
      expect(response.body).not_to include('kunde-a')
      get edit_organisation_tag_path(organisation, tag)
      expect(response).to redirect_to(root_path)
      get new_merge_organisation_tag_path(organisation, tag)
      expect(response).to redirect_to(root_path)
      patch organisation_tag_path(organisation, tag), params: { tag: { name: 'umbenannt' } }
      post merge_organisation_tag_path(organisation, tag), params: { target_id: target.id }
      delete organisation_tag_path(organisation, tag)

      expect(tag.reload.name).to eq('kunde-a')
      expect(Tagging.where(tag_id: tag.id).count).to eq(1)
      expect(Tag.exists?(target.id)).to be(true)
    end

    it 'sends a visitor without a session to the sign-in' do
      get organisation_tags_path(organisation)

      expect(response).to redirect_to(new_user_session_path)
    end

    # One request each: in a request spec the 404 page ends the session.
    it 'does not find a tag of another organisation, also for an admin' do
      foreign = tag!('fremd', org: other_organisation)
      sign_in admin

      get edit_organisation_tag_path(organisation, foreign)

      expect(response).to have_http_status(:not_found)
    end

    it 'deletes no tag of another organisation' do
      foreign = tag!('fremd', org: other_organisation)
      sign_in admin

      delete organisation_tag_path(organisation, foreign)

      expect(response).to have_http_status(:not_found)
      expect(Tag.unscoped.exists?(foreign.id)).to be(true)
    end
  end

  describe 'the list' do
    before { sign_in admin }

    it 'counts the entries per kind and in all, a deleted time entry not' do
      tag = tag!('kunde-a')
      2.times { ticket_with(tag) }
      tagged(:note, tag)
      tagged(:document, tag)
      tagged(:time_session, tag)
      tagged(:time_session, tag).update_column(:deleted_at, Time.current)

      get organisation_tags_path(organisation)

      row = page_of(response).at_css("tr##{ActionView::RecordIdentifier.dom_id(tag)}")
      expect(row.css('td').map { |cell| cell.text.squish }.first(6)).to eq(%w[kunde-a 2 1 1 1 5])
    end

    it 'shows a tag nothing carries with 0, and offers rename, merge and delete in its menu' do
      unused = tag!('vergessen')
      tag!('kunde-a')

      get organisation_tags_path(organisation)

      row = page_of(response).at_css("tr##{ActionView::RecordIdentifier.dom_id(unused)}")
      expect(row.css('td')[5].text.squish).to eq('0')
      expect(row.css('.more-menu__items a').pluck('href'))
        .to eq([edit_organisation_tag_path(organisation, unused), new_merge_organisation_tag_path(organisation, unused)])
      delete_form = row.at_css(".more-menu__items form[action='#{organisation_tag_path(organisation, unused)}']")
      expect(delete_form['data-turbo-confirm']).to eq(I18n.t('views.organisations.tags.index.confirm_delete', name: 'vergessen', count: 0))
    end

    it 'names the uses in the question before deleting' do
      tag = tag!('kunde-a')
      3.times { ticket_with(tag) }

      get organisation_tags_path(organisation)

      expect(page_of(response).at_css('.more-menu__items form')['data-turbo-confirm'])
        .to eq(I18n.t('views.organisations.tags.index.confirm_delete', name: 'kunde-a', count: 3))
    end

    it 'narrows the rows to the search' do
      tag!('kunde-a')
      tag!('intern')

      get organisation_tags_path(organisation, q: 'KUNDE')

      names = page_of(response).css('[data-tag-list] tbody tr td:first-child').map { |cell| cell.text.squish }
      expect(names).to eq(%w[kunde-a])
    end

    it 'sorts by name, by uses most first, and the other way round on the second click' do
      rare = tag!('alpha')
      often = tag!('beta')
      ticket_with(rare)
      3.times { ticket_with(often) }

      names = lambda do |**sorting|
        get organisation_tags_path(organisation, **sorting)
        page_of(response).css('[data-tag-list] tbody tr td:first-child').map { |cell| cell.text.squish }
      end

      expect(names.call).to eq(%w[alpha beta])
      expect(names.call(sort: 'uses', direction: 'desc')).to eq(%w[beta alpha])
      expect(names.call(sort: 'uses', direction: 'asc')).to eq(%w[alpha beta])
      expect(names.call(sort: 'uses; DROP TABLE tags', direction: 'sideways')).to eq(%w[alpha beta])
    end

    # The tag field gets its suggestions with the form (TagsHelper), the list
    # answers HTML only. (The error page of the test shows this file, so the body
    # is not searched for a name.)
    it 'has no JSON list of the names any more' do
      tag!('kunde-a')

      get organisation_tags_path(organisation, format: :json)

      expect(response).to have_http_status(:not_acceptable)
    end

    it 'says how tags come about while there is none' do
      get organisation_tags_path(organisation)

      expect(response.body).to include(I18n.t('views.organisations.tags.index.empty_title'))
      expect(page_of(response).at_css('[data-tag-list]')).to be_nil
    end
  end

  describe 'renaming' do
    before { sign_in admin }

    it 'renames the tag and the saved filters of this organisation that name it' do
      tag = tag!('kunde-a')
      ticket = ticket_with(tag)
      rule = tag_rule('intern,kunde-a')
      single = tag_rule('Kunde-A', operator: SmartFolders::Operators::HAS)
      foreign_rule = tag_rule('kunde-a', org: other_organisation)

      patch organisation_tag_path(organisation, tag), params: { tag: { name: '  Kunde Alpha ' } }

      expect(response).to redirect_to(organisation_tags_path(organisation))
      expect(flash[:notice]).to eq(I18n.t('flash.tags.renamed', old: 'kunde-a', new: 'kunde alpha'))
      expect(tag.reload.name).to eq('kunde alpha')
      expect(ticket.reload.tag_list).to eq(['kunde alpha'])
      expect([rule.reload.value, rule.display_value]).to eq(['intern,kunde alpha', 'intern,kunde alpha'])
      expect(single.reload.value).to eq('kunde alpha')
      expect(foreign_rule.reload.value).to eq('kunde-a')
    end

    it 'says nothing for the name the tag has, in another spelling too' do
      tag = tag!('kunde-a')

      patch organisation_tag_path(organisation, tag), params: { tag: { name: ' Kunde-A' } }

      expect(response).to redirect_to(organisation_tags_path(organisation))
      expect(flash[:notice]).to be_nil
      expect(tag.reload.name).to eq('kunde-a')
    end

    it 'refuses the name of another tag and offers to merge into it' do
      tag = tag!('kunde-a')
      other = tag!('kunde a')

      patch organisation_tag_path(organisation, tag), params: { tag: { name: 'Kunde A' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(tag.reload.name).to eq('kunde-a')
      error = page_of(response).at_css('#tag-name-error')
      expect(error.text).to include(I18n.t('services.actors.rename_tag.name_taken', name: 'kunde a'))
      expect(error.at_css('a')['href']).to eq(new_merge_organisation_tag_path(organisation, tag, target_id: other.id))
    end

    { blank: '   ', separator: 'kunde,a', too_long: 'k' * (Tag::MAX_NAME_LENGTH + 1) }.each do |problem, name|
      it "refuses a name with the problem #{problem} and keeps the old name" do
        tag = tag!('kunde-a')

        patch organisation_tag_path(organisation, tag), params: { tag: { name: name } }

        expect(response).to have_http_status(:unprocessable_content)
        field = page_of(response).at_css('#tag-name')
        expect(field['aria-invalid']).to eq('true')
        expect(field['value'].to_s).to eq(name)
        expect(page_of(response).at_css('#tag-name-error').text.squish)
          .to eq(I18n.t("services.actors.rename_tag.#{problem}", count: Tag::MAX_NAME_LENGTH))
        expect(tag.reload.name).to eq('kunde-a')
      end
    end

    it 'names the section and the tag in the crumb line of the form' do
      tag = tag!('kunde-a')

      get edit_organisation_tag_path(organisation, tag)

      crumb = page_of(response).at_css('[data-section-crumb]')
      expect(crumb.at_css('a')['href']).to eq(organisation_tags_path(organisation))
      expect(crumb.at_css('[aria-current="page"]').text).to eq(I18n.t('views.organisations.tags.edit.title', name: 'kunde-a'))
    end
  end

  describe 'merging' do
    before { sign_in admin }

    it 'gives every entry the target once, deletes the tag and points the saved filters at the target' do
      source = tag!('kunde-a')
      target = tag!('kunde a')
      only_source = ticket_with(source)
      both = ticket_with(source, target)
      note = tagged(:note, source)
      any_rule = tag_rule('kunde-a,kunde a')
      not_rule = tag_rule('kunde-a', operator: SmartFolders::Operators::NOT_HAS)

      post merge_organisation_tag_path(organisation, source), params: { target_id: target.id }

      expect(response).to redirect_to(organisation_tags_path(organisation))
      expect(Tag.exists?(source.id)).to be(false)
      expect(Tagging.where(tag_id: target.id).pluck(:taggable_id)).to contain_exactly(only_source.id, both.id, note.id)
      expect(Tagging.where(tag_id: source.id)).to be_empty
      expect(SmartFolderRule.where(id: [any_rule.id, not_rule.id]).pluck(:value)).to eq(['kunde a', 'kunde a'])
    end

    it 'refuses a tag of another organisation as the target and moves nothing' do
      source = tag!('kunde-a')
      ticket_with(source)
      foreign = tag!('kunde a', org: other_organisation)

      post merge_organisation_tag_path(organisation, source), params: { target_id: foreign.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Tagging.where(tag_id: source.id).count).to eq(1)
      expect(Tag.exists?(source.id)).to be(true)
    end

    # The tag itself is no target, and neither is a target sent as a hash.
    %i[itself hash].each do |kind|
      it "refuses a target that is no other tag of the organisation (#{kind})" do
        source = tag!('kunde-a')
        tag!('kunde a')
        target_id = kind == :itself ? source.id : { id: source.id }

        post merge_organisation_tag_path(organisation, source), params: { target_id: target_id }

        expect(response).to have_http_status(:unprocessable_content)
        expect(page_of(response).at_css('#tag-merge-error').text).to eq(I18n.t('services.actors.merge_tags.no_target'))
        expect(Tag.exists?(source.id)).to be(true)
      end
    end

    it 'offers every other tag as the target and keeps the one the rename named' do
      source = tag!('kunde-a')
      tag!('alpha')
      taken = tag!('kunde a')

      get new_merge_organisation_tag_path(organisation, source, target_id: taken.id)

      select = page_of(response).at_css('select#tag-merge-target')
      expect(select.css('option').map(&:text)).to eq([I18n.t('views.organisations.tags.new_merge.choose'), 'alpha', 'kunde a'])
      expect(select.at_css('option[selected]')['value']).to eq(taken.id)
    end
  end

  describe 'deleting' do
    before { sign_in admin }

    it 'deletes the tag from every entry and keeps the entries and the saved filters' do
      tag = tag!('kunde-a')
      ticket = ticket_with(tag)
      rule = tag_rule('kunde-a', operator: SmartFolders::Operators::HAS)

      delete organisation_tag_path(organisation, tag)

      expect(response).to redirect_to(organisation_tags_path(organisation))
      expect(response).to have_http_status(:see_other)
      expect(Tag.exists?(tag.id)).to be(false)
      expect(ticket.reload.tag_list).to be_empty
      expect(rule.reload.value).to eq('kunde-a')
    end
  end
end
