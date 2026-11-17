require_dependency 'issue'

module RedmineFinalDate
  # What the plugin adds to Issue:
  #
  # * a subtask's start_date must not be later than the final date of its
  #   branch owner (the original validation);
  # * a subtask always carries the owner's final date (sync_subtasks);
  # * a top-level issue whose final date has passed cannot be saved by an
  #   employee while it sits on an employee in one of the configured statuses
  #   (overdue_guard), and no subtask can be created under it
  #   (overdue_block_subtasks).
  #
  # Everything new is off until switched on in the plugin settings.
  module CustomValidationPatch
    def self.included(base)
      base.class_eval do
        unloadable
        # init.rb re-requires this file on every Rails.configuration.to_prepare,
        # so `included` fires repeatedly in development. That is safe: Active
        # Support deduplicates callbacks that share a symbol filter, so each
        # stays registered exactly once.
        validate :check_subtask_start_date, on: :update
        validate :rfd_check_overdue_final_date
        validate :rfd_check_subtask_under_overdue_owner
        validate :rfd_check_overdue_date_stays_in_force
        before_save :rfd_take_owner_final_date
        after_save :rfd_push_final_date_down
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

    # --- a final date in the past ------------------------------------------

    # The top-level issue itself. Judged by what is being saved, so the same
    # save that moves the date forward, clears it, hands the issue to the
    # customer or takes it out of the listed statuses goes through.
    def rfd_check_overdue_final_date
      settings = RedmineFinalDate::Settings
      return unless settings.overdue_guard?
      return if parent_issue_id.present?

      final_date = settings.final_date_for(self)
      return if final_date.nil? || final_date >= settings.today
      return unless settings.overdue_status_ids.include?(status_id)
      return unless settings.staff_principal?(assigned_to)
      return unless settings.staff_actor?

      errors.add(:base, l(:error_rfd_final_date_overdue, date: format_date(final_date)))
    rescue StandardError => e
      rfd_log_failure('overdue check', e)
    end

    # A new subtask anywhere in the branch — or an existing issue being moved
    # into it, which is the same thing done in two steps.
    def rfd_check_subtask_under_overdue_owner
      settings = RedmineFinalDate::Settings
      return unless settings.block_subtasks?
      return if parent_issue_id.blank?
      return unless new_record? || parent_issue_id.to_s != parent_id.to_s
      return unless settings.staff_actor?

      owner = settings.owner_after_save(self)
      return if owner.nil?
      # Moving a subtask around inside its own branch brings nothing new into it.
      return if persisted? && root_id == owner.id

      final_date = settings.final_date_for(owner)
      return if final_date.nil? || final_date >= settings.today

      errors.add(:base, l(:error_rfd_subtask_under_overdue_owner,
                          id: owner.id, date: format_date(final_date)))
    rescue StandardError => e
      rfd_log_failure('subtask check', e)
    end

    # A date that has passed stops applying only when someone moves or clears
    # it — not as a side effect. Two side effects would otherwise do it for an
    # issue that owns such a date: putting it under a parent (with
    # sync_subtasks on it takes the new owner's date; either way it is no
    # longer judged as an owner), and switching it to a tracker or project that
    # does not carry the field (the stored row stays behind, out of sight).
    # Both are refused to an employee, whatever the status and the assignee;
    # the same save may move or clear the date and then goes through.
    # Found by the acceptance review: this was a way around both rules.
    def rfd_check_overdue_date_stays_in_force
      settings = RedmineFinalDate::Settings
      return unless settings.overdue_guard? || settings.block_subtasks?
      return unless persisted? && parent_id_in_database.blank?

      field = settings.custom_field
      return if field.nil?

      still_holds = settings.holds_field?(self, field)
      leaving = parent_issue_id.present?
      dropping = !still_holds && (tracker_id_changed? || project_id_changed?)
      return unless leaving || dropping
      return unless settings.staff_actor?

      final_date =
        if still_holds
          settings.final_date_for(self)
        else
          stored = Issue.find_by(id: id)
          settings.holds_field?(stored, field) ? settings.final_date_for(stored) : nil
        end
      return if final_date.nil? || final_date >= settings.today

      errors.add(:base, l(:error_rfd_overdue_date_first, date: format_date(final_date)))
    rescue StandardError => e
      rfd_log_failure('overdue date kept in force check', e)
    end

    # --- subtasks mirror the owner's date ----------------------------------

    # A subtask does not own a final date: whatever it is being saved with, it
    # leaves with the owner's. That covers creation, moving to another parent
    # and any attempt to edit the date on the subtask itself (the form hides
    # the field, bulk edit and the API do not).
    #
    # When the owner's tracker cannot hold the field there is no authoritative
    # value for the branch, and the subtask is left as it is.
    def rfd_take_owner_final_date
      @rfd_final_date_before = nil
      settings = RedmineFinalDate::Settings
      return unless settings.sync_subtasks?

      field = settings.custom_field
      return if field.nil?

      @rfd_final_date_before = custom_value_for(field)&.value.to_s
      return if parent_issue_id.blank? || !settings.holds_field?(self, field)

      owner = settings.owner_after_save(self)
      return unless settings.holds_field?(owner, field)

      wanted = owner.custom_field_value(field.id).to_s
      self.custom_field_values = { field.id.to_s => wanted } if custom_field_value(field.id).to_s != wanted
    rescue StandardError => e
      rfd_log_failure('taking the owner date', e)
    end

    # The date of this issue changed, or the issue moved: everything below it
    # must follow.
    def rfd_push_final_date_down
      before = @rfd_final_date_before
      @rfd_final_date_before = nil
      return if before.nil? || saved_change_to_id?

      settings = RedmineFinalDate::Settings
      field = settings.custom_field
      return if field.nil?

      owner = parent_id.present? ? settings.owner_of(self) : self
      return unless settings.holds_field?(owner, field)

      # For the owner itself take the value just assigned: its own row is
      # written by another after_save and may not be in the database yet.
      value = (owner.equal?(self) ? custom_field_value(field.id) : owner.custom_field_value(field.id)).to_s
      return if before == value && !saved_change_to_parent_id?

      # A savepoint of its own: a database error in here (a deadlock with a
      # subtask being saved at the same moment, say) must roll back only the
      # mirroring, not poison the transaction the issue itself is saved in.
      Issue.transaction(requires_new: true) do
        RedmineFinalDate::SubtaskMirror.push_down(self, field, value)
      end
    rescue StandardError => e
      rfd_log_failure('pushing the date down', e)
    end

    # None of this may break an issue save: a failure here is logged and the
    # save goes on as if the plugin were not installed.
    def rfd_log_failure(what, error)
      Rails.logger.warn("[RedmineFinalDate] #{what} failed for issue ##{id}: #{error.class}: #{error.message}")
      true
    end
  end

  module IssuePatch
    def self.included(base)
      base.send(:include, CustomValidationPatch)
    end
  end
end

Issue.send(:include, RedmineFinalDate::IssuePatch)
