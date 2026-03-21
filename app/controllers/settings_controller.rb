class RedmineFinalDate::SettingsController < ApplicationController
  layout 'admin'
  before_action :require_admin

  def show
    @settings = Setting.plugin_redmine_final_date
  end

  def update
    Setting.plugin_redmine_final_date = params[:settings]
    redirect_to settings_redmine_final_date_path, notice: l(:notice_successful_update)
  end
end
