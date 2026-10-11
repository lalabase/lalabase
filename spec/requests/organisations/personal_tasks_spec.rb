# frozen_string_literal: true

require 'rails_helper'

# End-to-end privacy + behaviour of the Notizblock endpoints. The key walls:
# a member can only create their OWN task (user_id is not mass-assignable), a
# same-org foreign-user id is denied by Pundit (302, NOT 403 — that is the app
# convention), and a cross-org id is invisible to the tenant scope (404).
RSpec.describe 'Organisations personal tasks', type: :request do
  let(:organisation)       { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  def member(org = organisation)
    user = create(:user)
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org, title: "Member #{SecureRandom.hex(4)}", is_default: true)
      create(:membership, user: user, organisation: org, role: role, active: true)
    end
    user
  end

  # An account_admin of the org — used to prove the endpoints grant NO admin bypass.
  def org_admin(org = organisation)
    user = create(:user)
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org, title: 'account_admin')
      create(:membership, user: user, organisation: org, role: role, active: true)
    end
    user
  end

  let(:owner)        { member }
  let(:other_member) { member }
  let(:admin)        { org_admin }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # The Rack middleware resets the tenant after each request, so tenanted reads
  # in expectations must re-enter the tenant context.
  def task_for(user, org: organisation, **attrs)
    ActsAsTenant.with_tenant(org) { create(:personal_task, user: user, organisation: org, **attrs) }
  end

  def task_count(org = organisation)
    ActsAsTenant.with_tenant(org) { PersonalTask.count }
  end

  def last_task(org = organisation)
    ActsAsTenant.with_tenant(org) { PersonalTask.order(:created_at).last }
  end

  describe 'POST create' do
    it 'creates a to-do owned by the current user' do
      sign_in owner

      expect do
        post organisation_personal_tasks_path(organisation_id: organisation.id),
             params: { personal_task: { title: 'Rückruf Kunde X', priority: 'high' } }
      end.to change { task_count }.by(1)

      task = last_task
      expect(task.user).to eq(owner)
      expect(task.title).to eq('Rückruf Kunde X')
      expect(task.priority).to eq('high')
      expect(response).to redirect_to(organisation_personal_tasks_path(organisation_id: organisation.id))
    end

    it 'forces ownership to current_user even if user_id is injected (not mass-assignable)' do
      sign_in owner

      post organisation_personal_tasks_path(organisation_id: organisation.id),
           params: { personal_task: { title: 'mine', user_id: other_member.id } }

      expect(last_task.user).to eq(owner)
    end

    it 'rejects a blank title without creating a row' do
      sign_in owner

      expect do
        post organisation_personal_tasks_path(organisation_id: organisation.id),
             params: { personal_task: { title: '   ' } }
      end.not_to(change { task_count })
    end
  end

  describe 'PATCH update (toggle done)' do
    it 'lets the owner toggle completion' do
      task = task_for(owner)
      sign_in owner

      patch organisation_personal_task_path(organisation_id: organisation.id, id: task.id),
            params: { toggle_completed: '1' }

      expect(task.reload.completed?).to be(true)
    end

    it 'denies a different member (302) and leaves the task open' do
      task = task_for(owner)
      sign_in other_member

      patch organisation_personal_task_path(organisation_id: organisation.id, id: task.id),
            params: { toggle_completed: '1' }

      expect(response).to have_http_status(:found) # Pundit -> redirect, NOT 403
      expect(task.reload.completed?).to be(false)
    end
  end

  describe 'PATCH update (priority flag)' do
    it 'sets a priority on the owner\'s task' do
      task = task_for(owner)
      sign_in owner

      patch organisation_personal_task_path(organisation_id: organisation.id, id: task.id),
            params: { personal_task: { priority: 'high' } }

      expect(task.reload.priority).to eq('high')
    end

    it 'clears the priority when the flag cycles back to none (blank -> nil)' do
      task = task_for(owner, priority: :high)
      sign_in owner

      patch organisation_personal_task_path(organisation_id: organisation.id, id: task.id),
            params: { personal_task: { priority: '' } }

      expect(task.reload.priority).to be_nil
    end
  end

  describe 'DELETE destroy' do
    it 'lets the owner delete their task' do
      task = task_for(owner)
      sign_in owner

      expect do
        delete organisation_personal_task_path(organisation_id: organisation.id, id: task.id)
      end.to change { task_count }.by(-1)
    end

    it 'denies a different member (302); the task survives' do
      task = task_for(owner)
      sign_in other_member

      expect do
        delete organisation_personal_task_path(organisation_id: organisation.id, id: task.id)
      end.not_to(change { task_count })

      expect(response).to have_http_status(:found)
    end

    it 'cannot reach a task in another organisation (404, survives)' do
      foreign = task_for(owner, org: other_organisation)
      sign_in owner

      delete organisation_personal_task_path(organisation_id: organisation.id, id: foreign.id)

      expect(response).to have_http_status(:not_found)
      expect(task_count(other_organisation)).to eq(1)
    end
  end

  describe 'GET index' do
    it 'shows only the current user\'s tasks, never another member\'s' do
      task_for(owner, title: 'meins-titel')
      task_for(other_member, title: 'fremd-titel')
      sign_in owner

      get organisation_personal_tasks_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('meins-titel')
      expect(response.body).not_to include('fremd-titel')
    end
  end

  # The "different member" cases above prove the owner gate fires; these prove the gate has NO
  # account_admin bypass at the HTTP layer (the policy spec proves it in isolation, this proves the
  # controller actually authorizes and the side effect never happens). Mutation killed: adding an
  # account_admin shortcut to PersonalTaskPolicy#owner?, or dropping `authorize @task`.
  describe 'org admin has NO bypass (integration)' do
    it "cannot toggle another member's task (302, stays open)" do
      task = task_for(owner)
      sign_in admin

      patch organisation_personal_task_path(organisation_id: organisation.id, id: task.id),
            params: { toggle_completed: '1' }

      expect(response).to have_http_status(:found)
      expect(task.reload.completed?).to be(false)
    end

    it "cannot change another member's priority (302, unchanged)" do
      task = task_for(owner) # priority nil
      sign_in admin

      patch organisation_personal_task_path(organisation_id: organisation.id, id: task.id),
            params: { personal_task: { priority: 'high' } }

      expect(response).to have_http_status(:found)
      expect(task.reload.priority).to be_nil
    end

    it "cannot delete another member's task (302, survives)" do
      task = task_for(owner)
      sign_in admin

      expect do
        delete organisation_personal_task_path(organisation_id: organisation.id, id: task.id)
      end.not_to(change { task_count })

      expect(response).to have_http_status(:found)
    end

    it "sees only their own tasks on index, never a member's" do
      task_for(owner, title: 'fremd-fuer-admin')
      sign_in admin

      get organisation_personal_tasks_path(organisation_id: organisation.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('fremd-fuer-admin')
    end
  end

  # The HTML redirects above are the no-JS fallback; the real drawer path is a
  # turbo-stream that re-renders the panel. These pin that primary path so CI
  # catches a broken stream/template without needing a browser.
  describe 'turbo_stream rendering (the real drawer path)' do
    it 'create returns a panel-updating stream containing the new task' do
      sign_in owner

      post organisation_personal_tasks_path(organisation_id: organisation.id),
           params: { personal_task: { title: 'Frische Notiz' } }, as: :turbo_stream

      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('personal_tasks_panel')
      expect(response.body).to include('Frische Notiz')
    end

    it 'create with a blank title re-renders the panel with the error (422)' do
      sign_in owner

      post organisation_personal_tasks_path(organisation_id: organisation.id),
           params: { personal_task: { title: '' } }, as: :turbo_stream

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('personal_tasks_panel')
    end

    it 'destroy returns a panel-updating stream without the deleted task' do
      task = task_for(owner, title: 'gleich-weg')
      sign_in owner

      delete organisation_personal_task_path(organisation_id: organisation.id, id: task.id),
             as: :turbo_stream

      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('personal_tasks_panel')
      expect(response.body).not_to include('gleich-weg')
    end
  end
end
