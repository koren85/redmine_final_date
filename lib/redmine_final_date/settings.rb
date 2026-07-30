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
  end
end
