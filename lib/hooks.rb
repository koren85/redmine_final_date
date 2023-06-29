module RedmineFinalDate
  class Hooks < Redmine::Hook::ViewListener
    include ActionView::Helpers::TagHelper
    def view_layouts_base_html_head(context = {})
      stylesheet_link_tag 'custom_styles', plugin: 'redmine_final_date'
    end
    def view_issues_show_details_bottom(context = {})
      issue = context[:issue]
      parent_issue = issue.parent
      custom_field_id = Setting.plugin_redmine_final_date['custom_field_id'].to_i

      if parent_issue && parent_issue.custom_field_values.any?
        custom_field_value = parent_issue.custom_field_values.detect { |cfv| cfv.custom_field_id == custom_field_id }  # Замените 1 на ID вашего кастомного поля
        date_value = custom_field_value.value if custom_field_value

        if date_value.present?
          formatted_date = I18n.l(date_value.to_date, format: :long, locale: :ru)  # Форматирование даты для русского языка
          if date_value.to_date <= Date.today
            return content_tag(:p, "Итоговая дата из родительской задачи: <span class='red'>#{formatted_date}</span>".html_safe)
          else
            return content_tag(:p, "Итоговая дата из родительской задачи: <span class='blue'>#{formatted_date}</span>".html_safe)
          end
          # return content_tag(:p, "Итоговая дата из родительской задачи: #{formatted_date}".html_safe, style: 'color: red; font-weight: bold;')
        end
      end

      ''
    end
      end
end
