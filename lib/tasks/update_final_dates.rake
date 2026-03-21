namespace :redmine do
  namespace :final_date do
    desc "Update the configured date custom field on issues matching the saved filter"
    task update_dates: :environment do
      RedmineFinalDate::DateUpdater.new.run
    end
  end
end
