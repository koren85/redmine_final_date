module RedmineFinalDate
  # Bulk-updates the "final date" custom field on every issue matched by a saved
  # IssueQuery. Driven by the redmine:final_date:update_dates rake task, which is
  # meant to run from cron.
  class DateUpdater
    # Provides add_working_days(date, n) — uses Setting.non_working_week_days
    include Redmine::Utils::DateCalculation

    def initialize(settings = nil)
      @settings = settings || RedmineFinalDate::Settings.all
    end

    # Entry point called from the rake task.
    # Returns { updated: N, skipped: N, failed: N }
    def run
      results = { updated: 0, skipped: 0, failed: 0 }

      return results unless custom_field_configured?

      query = find_query
      return results unless query

      # IMPORTANT: Issue.visible uses User.current for visibility checks.
      # In a rake task context User.current defaults to User.anonymous which
      # has no project access → query returns 0 results.
      # Set to a privileged user before calling query.issues.
      previous_user = User.current
      User.current = resolve_global_acting_user

      begin
        issues = query.issues
        log "Processing #{issues.size} issue(s) from query '#{query.name}' (##{query.id})"

        # Resolve every write up front so each issue is saved at most once, then
        # execute. See #build_plan for why the two phases are separate.
        plan = build_plan(issues, results)
        log "Planned #{plan.size} write(s)"

        plan.each_value do |entry|
          merge_results(results,
                        save_issue(entry[:issue], entry[:user], entry[:date],
                                   entry[:notes], label: entry[:label],
                                   journal: entry[:journal]))
        end
      ensure
        User.current = previous_user
      end

      log "Done. updated=#{results[:updated]}, skipped=#{results[:skipped]}, failed=#{results[:failed]}"
      results
    end

    private

    # ----------------------------------------------------------------
    # Configuration
    # ----------------------------------------------------------------

    # Without a valid custom field every save would be a no-op that still writes
    # a journal entry, so refuse to run at all.
    def custom_field_configured?
      id = @settings['custom_field_id'].to_i
      if id <= 0
        log 'custom_field_id not configured, aborting.'
        return false
      end
      unless CustomField.exists?(id: id)
        log "Custom field ##{id} no longer exists, aborting."
        return false
      end
      true
    end

    def find_query
      filter_id = @settings['filter_id'].to_i
      if filter_id <= 0
        log 'filter_id not configured, aborting.'
        return nil
      end

      query = IssueQuery.find_by(id: filter_id)
      log "IssueQuery ##{filter_id} not found, aborting." unless query
      query
    end

    # ----------------------------------------------------------------
    # Planning
    # ----------------------------------------------------------------

    # Returns an ordered Hash of issue_id => write instruction.
    #
    # The invariant this implements: an issue tree carries ONE final date. The
    # root owns it; every descendant mirrors it. So whichever issue the filter
    # matched, the write is planned against that issue's whole tree — climb to
    # `root_id`, then fan out over `descendants`. Matching a mid-level subtask
    # therefore also updates the root and its other branches, instead of leaving
    # the tree half-updated.
    #
    # Planning is separate from saving because the same issue is reachable from
    # several filter matches in the same tree. Saving during traversal wrote it
    # more than once, producing duplicate journal entries and notifications.
    def build_plan(issues, results)
      plan = {}

      # root_id is set for every issue by Redmine's nested set; a top-level
      # issue is its own root.
      issues.group_by { |i| i.root_id || i.id }.each do |root_id, group|
        plan_tree(plan, root_id, group, results)
      end

      plan
    end

    # Plan one whole issue tree: the root carries the journal and the comment,
    # every descendant is updated silently.
    def plan_tree(plan, root_id, filter_issues, results)
      root = Issue.find_by(id: root_id)
      unless root
        log "Root ##{root_id} not found, skipping tree (#{filter_issues.size} issue(s))."
        return results[:skipped] += filter_issues.size
      end

      # Use first filter issue as the source for date calculation and user resolution
      trigger     = filter_issues.first
      acting_user = resolve_acting_user(trigger)
      new_date    = calculate_new_date(trigger)

      unless acting_user
        log "Tree ##{root_id}: no acting user, skipping."
        return results[:skipped] += filter_issues.size
      end
      unless new_date
        log "Tree ##{root_id}: could not calculate date, skipping."
        return results[:skipped] += filter_issues.size
      end

      # A closed top-level issue is finished work. Skip the WHOLE branch, not
      # just the root: updating the descendants while leaving the owner alone
      # would push them out of sync with the very issue they mirror.
      if closed?(root)
        log "Tree ##{root_id}: top-level issue is closed, skipping the whole branch."
        return results[:skipped] += filter_issues.size
      end

      # Make it visible when the filter matched subtasks rather than the owner:
      # the date belongs to the top-level issue, so that is what gets written.
      non_roots = filter_issues.reject { |i| i.parent_id.nil? }
      if non_roots.any?
        log "Tree ##{root_id}: filter matched #{non_roots.size} subtask(s) " \
            "(#{non_roots.map(&:id).first(5).join(', ')}#{'…' if non_roots.size > 5}) " \
            "— writing the owning top-level issue ##{root_id} and its whole branch."
      end

      # Root: journalled, carries the comment. It is the only owner of the date.
      add_to_plan(plan, root, acting_user, new_date, comment_text, 'root', true)

      # Descendants at every depth: silent — no journal, and therefore no mail
      # and no Telegram, since both fire on journal creation.
      root.descendants.each do |subtask|
        # Closed subtasks are finished work — no point rewriting their dates.
        next if closed?(subtask)

        add_to_plan(plan, subtask, acting_user, new_date, '',
                    "subtask of ##{root_id}", false)
      end
    rescue => e
      # One broken tree must not abort the whole cron run.
      log "Tree ##{root_id}: exception — #{e.message}"
      results[:failed] += 1
    end

    # One write per issue. A journalled entry (the root) always wins over a
    # silent one, so an issue reachable both ways is never written twice.
    def add_to_plan(plan, issue, user, date, notes, label, journal)
      existing = plan[issue.id]
      return if existing && (existing[:journal] || !journal)

      plan[issue.id] = { issue: issue, user: user, date: date,
                         notes: notes, label: label, journal: journal }
    end

    def comment_text
      @settings['comment_text'].to_s
    end

    def closed?(issue)
      closed_status_ids.include?(issue.status_id)
    end

    def closed_status_ids
      @closed_status_ids ||= IssueStatus.where(is_closed: true).pluck(:id).to_set
    end

    # ----------------------------------------------------------------
    # Shared: init journal, set custom field, save
    # ----------------------------------------------------------------
    def save_issue(issue, acting_user, new_date, notes, label: nil, journal: true)
      label ||= issue.id.to_s
      cf_id_str = @settings['custom_field_id'].to_s

      # Issue#save runs permission-sensitive callbacks against User.current, so
      # act as the resolved user for the whole save, not just in the journal.
      previous_user = User.current
      begin
        User.current = acting_user

        if journal
          # init_journal must be called before custom_field_values= and before save
          resolved_notes = notes.to_s.gsub('{{date}}', format_date_for_comment(new_date))
          issue.init_journal(acting_user, resolved_notes)
        end
        # Without init_journal Redmine writes no journal entry at all, which is
        # exactly what silent subtask updates need: both Redmine mail and
        # redmine_notifier's Telegram push hang off Journal creation, so no
        # journal means no notification on any channel.

        issue.custom_field_values = { cf_id_str => new_date.to_s }

        if issue.save
          log "Issue ##{issue.id} (#{label}): cf_#{cf_id_str} → #{new_date} " \
              "(user: #{acting_user.login}#{journal ? '' : ', silent'})"
          { updated: 1, skipped: 0, failed: 0 }
        else
          log "Issue ##{issue.id} (#{label}): save failed — #{issue.errors.full_messages.join(', ')}"
          { updated: 0, skipped: 0, failed: 1 }
        end
      ensure
        User.current = previous_user
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
      configured_acting_user || first_admin
    end

    # Per-issue resolution: global setting → responsible custom field → first admin
    def resolve_acting_user(issue)
      configured_acting_user || responsible_user(issue) || first_admin
    end

    def configured_acting_user
      uid = @settings['acting_user_id'].to_i
      return nil unless uid > 0

      user = User.find_by(id: uid)
      user if user&.active?
    end

    def responsible_user(issue)
      rf_id = @settings['responsible_field_id'].to_i
      return nil unless rf_id > 0 && issue

      uid_str = issue.custom_field_value(rf_id)
      return nil if uid_str.blank?

      user = User.find_by(id: uid_str.to_i)
      user if user&.active?
    end

    def first_admin
      User.active.where(admin: true).order(:id).first
    end

    # ----------------------------------------------------------------
    # Date calculation
    # ----------------------------------------------------------------
    def calculate_new_date(issue)
      mode = @settings['date_mode'].to_s
      days = @settings['date_days'].to_i

      case mode
      when 'add_to_field'
        add_working_days(current_field_date(issue) || Date.today, days)
      when 'add_to_today'
        add_working_days(Date.today, days)
      when 'set_fixed'
        fixed_str = @settings['date_fixed'].presence
        return nil if fixed_str.blank?
        RedmineFinalDate::Settings.parse_date(fixed_str)
      else
        log "Unknown date_mode '#{mode}', cannot calculate date."
        nil
      end
    end

    def current_field_date(issue)
      raw = issue.custom_field_value(@settings['custom_field_id'].to_i)
      return nil if raw.blank?

      RedmineFinalDate::Settings.parse_date(raw)
    end

    # ----------------------------------------------------------------
    # Helpers
    # ----------------------------------------------------------------
    def format_date_for_comment(date)
      date.strftime('%d.%m.%Y')
    end

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
