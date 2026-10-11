# frozen_string_literal: true

module Admin
  class BeusersController < Admin::ApplicationController
    # before_action :check_permission

    def index
      @beusers = Beuser.all.order(:created_at)
    end

    def new
      @beuser = Beuser.new
      prepare_form
    end

    def edit
      @beuser = Beuser.find(params[:id])
      prepare_form
    end

    def update
      @beuser = Beuser.find(params[:id])
      if @beuser.update(beuser_update_params)
        redirect_to admin_beusers_path, notice: t('flash.admin.beusers.saved')
        nil
      else
        render :edit, status: :unprocessable_content
      end
    end

    def create
      @beuser = Beuser.new(beuser_params)
      if @beuser.save
        redirect_to admin_beusers_path, notice: t('flash.admin.beusers.created')
        nil
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit_password
      @beuser = Beuser.find(params[:id])
    end

    def update_password
      @beuser = Beuser.find(params[:id])
      @beuser.set_new_password(beuser_update_password_params[:password], beuser_update_password_params[:password_confirmation])
      if @beuser.save
        redirect_to admin_beusers_path, notice: t('flash.admin.beusers.password_changed')
        nil
      else
        prepare_form
        render :edit_password, status: :unprocessable_content
      end
    end

    def destroy
      @beuser = Beuser.find(params[:id])
      # Compare the loaded records, not the raw param: a UUID in another case or
      # format finds the same row but is a different string.
      if @beuser == current_user
        redirect_to admin_beusers_path, alert: t('flash.admin.beusers.cannot_delete_self')
        return
      end

      if @beuser.destroy
        flash[:notice] = t('flash.admin.beusers.deleted')
      else
        # The model refuses to delete the last active admin and says so.
        flash[:alert] = @beuser.errors.full_messages.to_sentence.presence || t('flash.admin.beusers.delete_failed')
      end
      redirect_to admin_beusers_path
    end

    private

    def prepare_form
      @role_hash = Beuser::ROLES.map { |x| [I18n.t("roles.#{x}"), x] }
    end

    def check_permission
      redirect_to admin_dashboard_url unless current_user.permission?('beusers')
    end

    def beuser_params
      params.require(:beuser).permit(:role, :active, :firstname, :lastname, :email, :password, :password_confirmation, { permissions: %i[users statistics translations_with_formatting projects_stats norge] })
    end

    def beuser_update_params
      params.require(:beuser).permit(:role, :active, :firstname, :lastname, :email, { permissions: %i[users statistics translations_with_formatting projects_stats norge] })
    end

    def beuser_update_password_params
      params.require(:beuser).permit(:password, :password_confirmation, :beuser_id)
    end
  end
end
