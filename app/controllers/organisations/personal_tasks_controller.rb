# frozen_string_literal: true

# A member's private "Notizblock" to-dos. The drawer (#index) renders the list +
# quick-add; #create / #update / #destroy are the quick-add, toggle-or-priority,
# and delete actions. Every mutation re-renders the whole panel via turbo_stream
# (small single-user list) so the open/done split and empty state stay correct.
#
# Privacy is enforced twice over:
#  - reads go through policy_scope (where user: current_user) AND acts_as_tenant,
#  - writes resolve the record tenant-scoped, then authorize owner-only.
# A same-org foreign-user id is found by the tenant scope, fails authorize, and
# lands in the Pundit handler (302). A cross-org id is not in the tenant scope at
# all -> RecordNotFound (404). New tasks always get user = current_user (never
# from params), so a member can only ever create their own.
class Organisations::PersonalTasksController < Organisations::BaseController
  before_action :set_task, only: %i[update destroy]

  # GET /org/:organisation_id/personal_tasks
  #
  # Panel content only — loaded lazily into the body-level drawer's turbo-frame,
  # never a standalone full page, so it renders WITHOUT the application layout.
  def index
    load_panel
    render layout: false
  end

  # POST /org/:organisation_id/personal_tasks
  def create
    # acts_as_tenant assigns organisation_id from the current tenant; we only
    # force the owner. user_id is NOT permitted, so it can never be spoofed.
    @task = PersonalTask.new(personal_task_params)
    @task.user = current_user
    authorize @task

    if @task.save
      load_panel
      respond_to do |format|
        format.turbo_stream # create.turbo_stream -> refresh panel (form resets)
        format.html { redirect_to organisation_personal_tasks_path(current_organisation) }
      end
    else
      # Re-render the panel with the INVALID task bound to the form, so the user
      # keeps their typed-in title and sees the validation message.
      load_panel(new_task: @task)
      respond_to do |format|
        format.turbo_stream { render :create, status: :unprocessable_entity }
        format.html do
          redirect_to organisation_personal_tasks_path(current_organisation),
                      alert: @task.errors.full_messages.to_sentence
        end
      end
    end
  end

  # PATCH /org/:organisation_id/personal_tasks/:id
  #
  # One action deliberately serves BOTH row controls — ticking the checkbox and
  # cycling the priority flag — because each is a one-field edit on the same row.
  # Folding them into one PATCH keeps the routes and the row markup minimal; the
  # param that is present tells us which one the user clicked.
  def update
    authorize @task

    if toggling_completion?
      @task.toggle_completed!
    else
      @task.update!(personal_task_update_params)
    end

    load_panel
    respond_to do |format|
      format.turbo_stream { render :update }
      format.html { redirect_to organisation_personal_tasks_path(current_organisation) }
    end
  end

  # DELETE /org/:organisation_id/personal_tasks/:id
  def destroy
    authorize @task
    @task.destroy

    load_panel
    respond_to do |format|
      format.turbo_stream { render :destroy }
      format.html { redirect_to organisation_personal_tasks_path(current_organisation) }
    end
  end

  private

  # Tenant-scoped lookup: a cross-org id is RecordNotFound (404); a same-org
  # foreign-user id is found here and then denied by authorize (302).
  def set_task
    @task = PersonalTask.find(params[:id])
  end

  # The checkbox posts `toggle_completed=1`; the priority flag posts a
  # `personal_task[...]` hash instead. So the presence of toggle_completed is what
  # distinguishes "tick the box" from "edit the priority".
  def toggling_completion?
    ActiveModel::Type::Boolean.new.cast(params[:toggle_completed])
  end

  # The single source of truth for everything the panel renders: the open/done
  # lists plus the task the quick-add form is bound to. `new_task` defaults to a
  # blank task; #create passes the invalid task back on a validation error so the
  # form keeps the typed-in title and shows the message.
  def load_panel(new_task: PersonalTask.new)
    tasks = policy_scope(PersonalTask).ordered
    @open_tasks = tasks.open
    @done_tasks = tasks.done
    @new_task = new_task
  end

  def personal_task_params
    params.require(:personal_task).permit(:title, :priority)
  end

  # A blank priority clears it (nil = no priority). The enum would otherwise raise
  # ArgumentError on an empty string.
  def personal_task_update_params
    permitted = params.require(:personal_task).permit(:priority)
    permitted[:priority] = nil if permitted[:priority].blank?
    permitted
  end
end
