Redmine::Plugin.register :redmine_final_date do
  name 'Redmine Final Date plugin'
  author 'Chernyaev A.A.'
  description 'Итоговая дата: одна на ветку задач, запрет работы при прошедшей дате'
  version '0.0.1'
  url ''
  author_url ''

  settings partial: 'redmine_final_date/settings', default: {
    'custom_field_id'      => '',
    'check_subtask'        => '0',
    'filter_id'            => '',
    'date_mode'            => 'add_to_today',
    'date_days'            => '0',
    'date_fixed'           => '',
    'comment_text'         => '',
    'acting_user_id'       => '',
    'responsible_field_id' => '',
    'cron_schedule'        => '0 16 * * 1-5',
    # Everything below is off until an admin switches it on.
    'sync_subtasks'          => '0',
    'overdue_guard'          => '0',
    'overdue_block_subtasks' => '0',
    'overdue_status_ids'     => [],
    'staff_group_ids'        => []
  }

end

Rails.configuration.to_prepare do
  Dir[File.dirname(__FILE__) + '/lib/*.rb'].each { |file| require_dependency file }
  Dir[File.dirname(__FILE__) + '/lib/redmine_final_date/**/*.rb'].each { |file| require_dependency file }
end
