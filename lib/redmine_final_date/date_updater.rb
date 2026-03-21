module RedmineFinalDate
  class DateUpdater
    # Provides add_working_days(date, n) — uses Setting.non_working_week_days
    include Redmine::Utils::DateCalculation

    def initialize(settings = nil)
      @settings = settings || Setting.plugin_redmine_final_date
    end

    # Entry point called from the rake task.
    # Returns { updated: N, skipped: N, failed: N }
    def run
      results = { updated: 0, skipped: 0, failed: 0 }

      filter_id = @settings['filter_id'].to_i
      unless filter_id > 0
        log 'filter_id not configured, aborting.'
        return results
      end

      query = IssueQuery.find_by(id: filter_id)
      unless query
        log "IssueQuery ##{filter_id} not found, aborting."
        return results
      end

      # IMPORTANT: Issue.visible uses User.current for visibility checks.
      # In a rake task context User.current defaults to User.anonymous which
      # has no project access → query returns 0 results.
      # Set to a privileged user before calling query.issues.
      previous_user = User.current
      User.current = resolve_global_acting_user

      begin
        issues = query.issues
        log "Processing #{issues.size} issue(s) from query '#{query.name}' (##{query.id})"

        # Split: top-level issues vs subtasks
        top_level, subtasks = issues.partition { |i| i.parent_id.nil? }

        # Top-level issues: update in-place, comment on themselves
        top_level.each do |issue|
          merge_results(results, process_standalone(issue))
        end

        # Subtasks: group by parent, handle each parent once
        subtasks.group_by(&:parent_id).each do |parent_id, group|
          merge_results(results, process_parent_group(parent_id, group))
        end
      ensure
        User.current = previous_user
      end

      log "Done. updated=#{results[:updated]}, skipped=#{results[:skipped]}, failed=#{results[:failed]}"
      results
    end

    private

    # ----------------------------------------------------------------
    # Top-level issue (no parent): update date + add comment on itself
    # ----------------------------------------------------------------
    def process_standalone(issue)
      acting_user = resolve_acting_user(issue)
      new_date    = calculate_new_date(issue)

      return log_skip(issue.id, 'no acting user') unless acting_user
      return log_skip(issue.id, 'could not calculate date') unless new_date

      save_issue(issue, acting_user, new_date, @settings['comment_text'].to_s)
    end

    # ----------------------------------------------------------------
    # Subtask group: update parent + ALL its subtasks; comment only on parent
    # ----------------------------------------------------------------
    def process_parent_group(parent_id, filter_issues)
      parent = Issue.find_by(id: parent_id)
      unless parent
        log "Parent ##{parent_id} not found, skipping group (#{filter_issues.size} issue(s))."
        return { updated: 0, skipped: filter_issues.size, failed: 0 }
      end

      # Use first filter issue as the source for date calculation and user resolution
      trigger     = filter_issues.first
      acting_user = resolve_acting_user(trigger)
      new_date    = calculate_new_date(trigger)

      unless acting_user
        log "Parent group ##{parent_id}: no acting user, skipping."
        return { updated: 0, skipped: filter_issues.size, failed: 0 }
      end
      unless new_date
        log "Parent group ##{parent_id}: could not calculate date, skipping."
        return { updated: 0, skipped: filter_issues.size, failed: 0 }
      end

      all_subtasks = Issue.where(parent_id: parent_id).to_a
      cf_id_str    = @settings['custom_field_id'].to_s
      results      = { updated: 0, skipped: 0, failed: 0 }

      previous_user = User.current
      begin
        User.current = acting_user

        # 1. Parent — with comment
        r = save_issue(parent, acting_user, new_date, @settings['comment_text'].to_s,
                       label: 'parent')
        merge_results(results, r)

        # 2. All subtasks — journal entry for the field change only (no notes text)
        all_subtasks.each do |subtask|
          r = save_issue(subtask, acting_user, new_date, '',
                         label: "subtask of ##{parent_id}")
          merge_results(results, r)
        end
      rescue => e
        log "Parent group ##{parent_id}: exception — #{e.message}"
        results[:failed] += 1
      ensure
        User.current = previous_user
      end

      results
    end

    # ----------------------------------------------------------------
    # Shared: init journal, set custom field, save
    # ----------------------------------------------------------------
    def save_issue(issue, acting_user, new_date, notes, label: nil)
      label ||= issue.id.to_s
      cf_id_str = @settings['custom_field_id'].to_s

      # init_journal must be called before custom_field_values= and before save
      issue.init_journal(acting_user, notes)
      issue.custom_field_values = { cf_id_str => new_date.to_s }

      if issue.save
        log "Issue ##{issue.id} (#{label}): cf_#{cf_id_str} → #{new_date} (user: #{acting_user.login})"
        { updated: 1, skipped: 0, failed: 0 }
      else
        log "Issue ##{issue.id} (#{label}): save failed — #{issue.errors.full_messages.join(', ')}"
        { updated: 0, skipped: 0, failed: 1 }
      end
    rescue => e
      log "Issue ##{issue.id} (#{label}): exception — #{e.message}"
      { updated: 0, skipped: 0, failed: 1 }
    end

    # ----------------------------------------------------------------
    # User resolution
    # ----------------------------------------------------------------

    # Used before query.issues to satisfy Issue.visible permission checks
    def resolve_global_acting_user
      uid = @settings['acting_user_id'].to_i
      if uid > 0
        u = User.find_by(id: uid)
        return u if u&.active?
      end
      User.active.where(admin: true).order(:id).first
    end

    # Per-issue resolution: global setting → responsible custom field → first admin
    def resolve_acting_user(issue)
      uid = @settings['acting_user_id'].to_i
      if uid > 0
        u = User.find_by(id: uid)
        return u if u&.active?
      end

      rf_id = @settings['responsible_field_id'].to_i
      if rf_id > 0
        uid_str = issue.custom_field_value(rf_id)
        if uid_str.present?
          u = User.find_by(id: uid_str.to_i)
          return u if u&.active?
        end
      end

      User.active.where(admin: true).order(:id).first
    end

    # ----------------------------------------------------------------
    # Date calculation
    # ----------------------------------------------------------------
    def calculate_new_date(issue)
      cf_id     = @settings['custom_field_id'].to_i
      mode      = @settings['date_mode'].to_s
      days      = @settings['date_days'].to_i
      fixed_str = @settings['date_fixed'].presence

      case mode
      when 'add_to_field'
        raw  = issue.custom_field_value(cf_id)
        base = if raw.present?
          begin; raw.to_date; rescue ArgumentError, TypeError; Date.today; end
        else
          Date.today
        end
        add_working_days(base, days)

      when 'add_to_today'
        add_working_days(Date.today, days)

      when 'set_fixed'
        return nil if fixed_str.blank?
        begin; fixed_str.to_date; rescue ArgumentError, TypeError; nil; end
      end
    end

    # ----------------------------------------------------------------
    # Helpers
    # ----------------------------------------------------------------
    def merge_results(target, source)
      source.each { |k, v| target[k] += v }
    end

    def log_skip(issue_id, reason)
      log "Issue ##{issue_id}: #{reason}, skipping."
      { updated: 0, skipped: 1, failed: 0 }
    end

    def log(message)
      puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] [RedmineFinalDate] #{message}"
    end
  end
end
