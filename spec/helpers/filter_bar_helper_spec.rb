# frozen_string_literal: true

require 'rails_helper'

# The three answers the menu at the active tab is built from
# (doc/filterleiste_s5_s8_plan.md, S5). The policy itself is pinned in
# spec/policies/smart_folder_policy_spec.rb; this only guards the mapping and
# the "no folder, no answers" case of the base view.
RSpec.describe FilterBarHelper, type: :helper do
  let(:folder) { instance_double(SmartFolder) }

  # `policy` is Pundit's controller helper, not a method of the module under
  # test, so the partial-double check has to stand aside for the stub.
  def stub_policy(update:, share:, destroy:)
    folder_policy = instance_double(SmartFolderPolicy, update?: update, share?: share, destroy?: destroy)
    without_partial_double_verification do
      allow(helper).to receive(:policy).with(folder).and_return(folder_policy)
    end
  end

  it 'maps update?, share? and destroy? onto rename, share and delete' do
    stub_policy(update: true, share: false, destroy: true)

    expect(helper.filter_bar_view_permissions(folder)).to eq(rename: true, share: false, delete: true)
  end

  it 'answers nothing at all for a reader the policy denies everywhere' do
    stub_policy(update: false, share: false, destroy: false)

    expect(helper.filter_bar_view_permissions(folder)).to eq(rename: false, share: false, delete: false)
  end

  it 'has no answers without a folder (the base view)' do
    expect(helper.filter_bar_view_permissions(nil)).to eq({})
  end
end
