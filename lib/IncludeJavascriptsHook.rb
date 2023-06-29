class IncludeJavascriptsHook < Redmine::Hook::ViewListener
  include ActionView::Helpers::TagHelper

  def view_issues_form_details_bottom(context = {})
    issue = context[:issue]
    custom_field_id = Setting.plugin_redmine_final_date['custom_field_id'].to_i

    if issue.parent.present? && issue.available_custom_fields.include?(CustomField.find(custom_field_id))

=begin
    javascript_tag <<-JS
            document.addEventListener("DOMContentLoaded", function() {
              var customField = document.querySelector("#issue_custom_field_values_#{custom_field_id}");
              if (customField) {
                customField.closest("div").style.display = "none";

              }
            });
    JS
=end

      javascript_tag <<-JS
// Функция для удаления элемента
function removeCustomField() {
  var element = document.getElementById("issue_custom_field_values_#{custom_field_id}");
  if (element) {
    var parent = element.parentNode;
    if (parent.tagName === "P") {
      parent.parentNode.removeChild(parent);
    }
  }
}

// Обработчик события DOMContentLoaded для выполнения кода после загрузки страницы
document.addEventListener("DOMContentLoaded", function() {
  // Удалить элемент при загрузке страницы
  removeCustomField();

  // Удалить элемент при каждом обновлении содержимого страницы
  var observer = new MutationObserver(function(mutationsList) {
    for (var mutation of mutationsList) {
      if (mutation.type === "childList") {
        removeCustomField();
      }
    }
  });

  var targetNode = document.body;

  // Наблюдение за изменениями в содержимом targetNode
  var config = { childList: true, subtree: true };
  observer.observe(targetNode, config);
});

      JS

      # javascript_tag("var myValue = #{value.to_json};") if value.present?
    end
  end

  def view_issues_show_details_bottom(context = {})
    issue = context[:issue]
    custom_field_id = Setting.plugin_redmine_final_date['custom_field_id'].to_i
    if issue.parent.present? && issue.available_custom_fields.include?(CustomField.find(custom_field_id))

      javascript_tag <<-JS
            document.addEventListener("DOMContentLoaded", function() {
              var customField = document.querySelector(".cf_#{custom_field_id}.attribute");
              if (customField) {
                customField.closest("div").style.display = "none";
              }
            });
      JS
    end

  end

=begin
  def controller_issues_edit_before_save(context={})
    issue = context[:issue]
    custom_field_id = Setting.plugin_redmine_final_date['custom_field_id'].to_i
    # Проверяем, что это подзадача и она имеет дату начала
    if issue.is_a?(Issue) && issue.start_date.present? && issue.parent_id.present?
      parent = Issue.find_by_id(issue.parent_id)

      # Проверяем, что существует родительская задача и она имеет кастомное поле с ID 81
      if parent.present? && parent.custom_field_value(custom_field_id).present?
        custom_field_value = parent.custom_field_value(custom_field_id).to_date

        # Проверяем, что дата начала подзадачи больше, чем значение кастомного поля
        if issue.start_date > custom_field_value
          return issue.errors.add(:start_date, "Дата начала должна быть меньше или равна значению кастомного поля")
           false
        end
      end
    end

    true
  end
=end




end