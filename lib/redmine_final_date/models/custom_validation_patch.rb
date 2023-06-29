module CustomValidationPatch
  def self.included(base)
    base.class_eval do
      unloadable
      validate :check_subtask_start_date, on: :update
    end
  end

  private

  def check_subtask_start_date
    #1
    flag=Setting.plugin_redmine_final_date['check_subtask']

    if (flag && parent_id) || (parent_id && !flag && start_date_changed?)
      custom_field_id = Setting.plugin_redmine_final_date['custom_field_id'].to_i

      parent = Issue.find_by_id(parent_id)
      if parent.custom_field_value(custom_field_id).present?
        custom_field_value = parent.custom_field_value(custom_field_id).to_date
        return unless  start_date > custom_field_value

        errors.add(:start_date, " подзадачи (#{start_date}) не может быть больше Итоговой даты родительской задачи (#{custom_field_value})")
        throw :abort
      end

    end
  end

  def parent_start_date
    parent_task = Issue.find_by(id: parent_id)
    parent_task.custom_field_value(1) || parent_task.start_date
  end
end

# Примените патч к модели задачи

require_dependency 'issue'

module IssuePatch
  def self.included(base)
    base.send(:include, CustomValidationPatch)
  end
end

Issue.send(:include, IssuePatch)
