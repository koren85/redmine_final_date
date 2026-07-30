namespace :redmine do
  namespace :final_date do
    desc "Update the configured date custom field on issues matching the saved filter"
    task update_dates: :environment do
      RedmineFinalDate::DateUpdater.new.run
    end

    desc "Repair: force every subtask's final date to match its top-level issue. " \
         "Dry-run unless APPLY=1. Closed issues skipped unless INCLUDE_CLOSED=1. " \
         "Writes silently — no journals, no notifications."
    task sync_subtasks: :environment do
      apply          = ENV['APPLY'].to_s == '1'
      include_closed = ENV['INCLUDE_CLOSED'].to_s == '1'
      puts apply ? '*** APPLY MODE — changes will be written ***' : '*** DRY RUN — nothing will be written (pass APPLY=1 to write) ***'
      RedmineFinalDate::SubtaskSync.new.run(apply: apply, include_closed: include_closed)
    end
  end
end
