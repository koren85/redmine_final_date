require_dependency 'issue'

module RedmineFinalDate
  # Adds a validation to Issue: a subtask's start_date must not be later than
  # the "final date" custom field of its parent issue.
  module CustomValidationPatch
    def self.included(base)
      base.class_eval do
        unloadable
        # init.rb re-requires this file on every Rails.configuration.to_prepare,
        # so `included` fires repeatedly in development. That is safe: Active
        # Support deduplicates callbacks that share a symbol filter, so the
        # validation stays registered exactly once.
        validate :check_subtask_start_date, on: :update
      end
    end

    private

    def check_subtask_start_date
      return if parent_id.blank? || start_date.blank?
      return unless RedmineFinalDate::Settings.check_all_subtasks? || start_date_changed?

      # Compare against the branch owner — the top-level issue — not the
      # immediate parent. A mid-level issue does not own a final date, so its
      # value is not authoritative even if it happens to carry one.
      owner = RedmineFinalDate::Settings.owner_of(self)
      final_date = RedmineFinalDate::Settings.final_date_for(owner)
      return if final_date.nil? || start_date <= final_date

      # Issue includes Redmine::I18n, so `l` and `format_date` are available here.
      errors.add(
        :start_date,
        l(:error_subtask_start_date_after_parent_final_date,
          start_date: format_date(start_date),
          final_date: format_date(final_date))
      )
    end
  end

  module IssuePatch
    def self.included(base)
      base.send(:include, CustomValidationPatch)
    end
  end
end

Issue.send(:include, RedmineFinalDate::IssuePatch)
