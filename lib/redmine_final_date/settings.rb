module RedmineFinalDate
  # Single point of access to the plugin settings.
  #
  # Redmine stores plugin settings as one serialized Hash and *replaces* the
  # defaults registered in init.rb with whatever the settings form posted — the
  # two are never merged (see Setting.find_or_default). A key the form omits
  # therefore vanishes from the hash after the first save, so every read has to
  # tolerate both a missing key and a stale/garbage value.
  module Settings
    TRUTHY = %w(1 true yes on).freeze

    module_function

    # Settings saved before a new key was introduced simply do not contain it,
    # so layer the stored hash over the registered defaults. Without this every
    # setting added after the admin last pressed Save reads as nil.
    def all
      defaults.merge(Setting.plugin_redmine_final_date || {})
    end

    def defaults
      Redmine::Plugin.find(:redmine_final_date).settings[:default] || {}
    rescue Redmine::PluginNotFound
      {}
    end

    def get(key)
      all[key.to_s]
    end

    def truthy?(value)
      TRUTHY.include?(value.to_s.strip.downcase)
    end

    # --- final date custom field ------------------------------------------

    def custom_field_id
      get('custom_field_id').to_i
    end

    # Returns the configured CustomField, or nil when the plugin has never been
    # configured or the field has since been deleted. Never raises.
    def custom_field
      id = custom_field_id
      id > 0 ? CustomField.find_by(id: id) : nil
    end

    def configured?
      custom_field.present?
    end

    # The issue that OWNS the final date for +issue+'s branch: the top-level
    # issue, always. An issue that has a parent is never an owner, even when it
    # has children of its own. Returns nil for a top-level issue itself — it owns
    # its date and has nothing above it to mirror.
    #
    # Resolved through the parent rather than through +issue.root_id+ so it stays
    # correct while a branch is being re-parented: the new parent_id is the value
    # being saved, and that parent's own root is already stable.
    def owner_of(issue)
      return nil if issue.nil? || issue.parent_id.blank?

      parent = Issue.find_by(id: issue.parent_id)
      parent&.root
    end

    # The owner +issue+ will have once the save in progress completes.
    #
    # owner_of reads parent_id, and Redmine copies the parent chosen in the form
    # into parent_id only in a before_save: during validation — and for a
    # subtask that is being created or moved — parent_id still holds the old
    # value (nil for a new record). The rules added in 2026-10 must look at
    # where the issue is going, so they use this; the older start_date
    # validation keeps using owner_of, exactly as before.
    def owner_after_save(issue)
      return nil if issue.nil?

      parent_id = issue.parent_issue_id
      return nil if parent_id.blank?

      parent = Issue.find_by(id: parent_id)
      parent&.root
    end

    # Can +issue+ carry the final date at all? The field is attached to some
    # trackers (and possibly some projects) only.
    def holds_field?(issue, field = custom_field)
      return false if issue.nil? || field.nil?

      issue.available_custom_fields.include?(field)
    end

    # Parsed value of the final-date custom field on +issue+, or nil when the
    # plugin is unconfigured, the field is blank, or the stored value does not
    # parse as a date.
    def final_date_for(issue)
      id = custom_field_id
      return nil if issue.nil? || id <= 0

      raw = issue.custom_field_value(id)
      return nil if raw.blank?

      parse_date(raw)
    end

    def parse_date(raw)
      raw.to_date
    rescue ArgumentError, TypeError
      nil
    end

    # --- subtask validation -----------------------------------------------

    # true  -> validate every subtask on update
    # false -> validate only subtasks whose start_date actually changed
    def check_all_subtasks?
      truthy?(get('check_subtask'))
    end

    # --- subtasks mirror the owner's date ------------------------------------

    # Keep every subtask's final date equal to its top-level issue's on each
    # save (see IssuePatch). Off by default: enabling it is a decision.
    def sync_subtasks?
      truthy?(get('sync_subtasks'))
    end

    # --- a final date in the past --------------------------------------------

    # Refuse to save a top-level issue whose final date has passed.
    def overdue_guard?
      truthy?(get('overdue_guard'))
    end

    # Refuse to create (or move in) a subtask under such an issue.
    def block_subtasks?
      truthy?(get('overdue_block_subtasks'))
    end

    # Statuses in which the top-level issue must not be saved.
    def overdue_status_ids
      id_list(get('overdue_status_ids'))
    end

    # Groups that make up "our people": employees and the department queues.
    def staff_group_ids
      id_list(get('staff_group_ids'))
    end

    # A multi-select posts ['', '12', '2'] — the leading blank comes from the
    # hidden field that lets the admin clear the list.
    def id_list(raw)
      Array(raw).map(&:to_i).select(&:positive?).uniq
    end

    # Is +principal+ one of ours: a selected group, or a user in one of them?
    # An empty list means nobody is — the rules stay dormant until an admin
    # says who the employees are.
    def staff_principal?(principal)
      ids = staff_group_ids
      return false if principal.nil? || ids.empty?
      return ids.include?(principal.id) if principal.is_a?(Group)

      (principal.group_ids & ids).any?
    end

    # Is this save an employee's own action? The rules bind employees only:
    # a customer cannot edit the date at all, and automation (the dispatcher,
    # the scenario engine, rake and background threads, where nobody is logged
    # in) must keep working — the first employee to touch the issue afterwards
    # is the one who has to deal with the date.
    #
    # An administrator is not an employee and is never bound, even when a
    # member of one of the groups (the owner's decision, 2026-10-12). That also
    # lets through automation that runs under an administrator's account.
    def staff_actor?(user = User.current)
      return false if staff_group_ids.empty?
      return false if user.nil? || !user.logged?
      return false if user.admin?
      return false if automation?

      staff_principal?(user)
    end

    # Thread flags set by redmine_process_button's scenario engine and by
    # redmine_neural_dispatcher around their own saves. Read as plain thread
    # keys so this plugin depends on neither.
    def automation?
      Thread.current[:pb_scenario_execution] || Thread.current[:nd_dispatcher_execution] ? true : false
    end

    def today
      User.current.today
    end
  end
end
