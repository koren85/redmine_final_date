# Plugin's routes
# See: http://guides.rubyonrails.org/routing.html
get 'settings', to: 'settings#show', as: 'settings_redmine_final_date'
post 'settings', to: 'settings#update', as: 'update_settings_redmine_final_date'
