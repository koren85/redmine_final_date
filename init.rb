Redmine::Plugin.register :redmine_final_date do
  name 'Redmine Final Date plugin'
  author 'Chernyaev A.A.'
  description 'Отображение итоговой даты в подзадачах'
  version '0.0.1'
  url ''
  author_url ''

  settings partial: 'redmine_final_date/settings', default: {
    'custom_field_id'      => '',
    'check_subtask'        => '',
    'filter_id'            => '',
    'date_mode'            => 'add_to_today',
    'date_days'            => '0',
    'date_fixed'           => '',
    'comment_text'         => '',
    'acting_user_id'       => '',
    'responsible_field_id' => '',
    'cron_schedule'        => '0 16 * * 1-5'
  }

end

Rails.configuration.to_prepare do
  Dir[File.dirname(__FILE__) + '/lib/*.rb'].each { |file| require_dependency file }
  Dir[File.dirname(__FILE__) + '/lib/redmine_final_date/**/*.rb'].each { |file| require_dependency file }
end
