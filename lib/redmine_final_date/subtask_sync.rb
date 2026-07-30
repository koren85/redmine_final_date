module RedmineFinalDate
  # One-off repair: force every subtask's final date to match the one owned by
  # the top-level issue of its branch.
  #
  # This exists because the propagation workflow only fires when somebody edits
  # the top-level issue. Branches that diverged before the workflow existed — or
  # while it only reached the first level — stay wrong until touched. This walks
  # all of them once.
  #
  # Writes go straight to custom_values, deliberately bypassing Issue#save:
  #
  # * no journal, and therefore no mail and no Telegram (both hang off Journal
  #   creation) — a data repair is not an event anyone should be notified about;
  # * none of the ~30 active custom workflows fire, so the repair cannot trip a
  #   WorkflowError or drag in unrelated side effects;
  # * updated_on is left alone, so the repair does not churn "last updated".
  #
  # Dry-run unless apply: true.
  class SubtaskSync
    Result = Struct.new(:to_set, :to_clear, :skipped_subtask_tracker,
                        :skipped_owner_tracker, :skipped_closed, :closed_owners,
                        :already_ok, :applied, keyword_init: true)

    def initialize(settings = nil)
      @settings = settings || RedmineFinalDate::Settings.all
    end

    # include_closed: closed issues are finished work — rewriting their dates is
    # churn nobody asked for, so they are left alone by default.
    def run(apply: false, include_closed: false)
      cf_id = @settings['custom_field_id'].to_i
      raise 'custom_field_id is not configured' unless cf_id > 0

      field = CustomField.find_by(id: cf_id)
      raise "Custom field ##{cf_id} does not exist" unless field

      tracker_ids = field.trackers.pluck(:id).to_set
      log "Field ##{cf_id} #{field.name.inspect} applies to #{tracker_ids.size} tracker(s)"

      values     = load_values(cf_id)   # issue_id => [row_id, raw value]
      closed_ids = IssueStatus.where(is_closed: true).pluck(:id).to_set
      tracker    = {}
      parent     = {}
      root       = {}
      closed     = {}
      Issue.pluck(:id, :parent_id, :root_id, :tracker_id, :status_id).each do |id, pid, rid, tid, sid|
        parent[id]  = pid
        root[id]    = rid || id
        tracker[id] = tid
        closed[id]  = closed_ids.include?(sid)
      end
      log "Closed issues are #{include_closed ? 'INCLUDED' : 'skipped'}"

      result = Result.new(to_set: [], to_clear: [], skipped_subtask_tracker: 0,
                          skipped_owner_tracker: 0, skipped_closed: 0,
                          closed_owners: 0, already_ok: 0, applied: 0)

      parent.each do |id, pid|
        next if pid.nil?                       # top-level issues own their date

        owner_id = root[id]
        next if owner_id == id                 # defensive: malformed tree

        want = normalize(values[owner_id]&.last)
        have = normalize(values[id]&.last)

        # Everything below counts only ACTUAL divergences, so that the buckets
        # partition one set and add up. Each subtask lands in exactly one bucket,
        # the first that matches.
        if want == have
          result.already_ok += 1
          next
        end

        # The owner cannot hold the field at all -> there is no authoritative
        # value for this branch. Leave it alone rather than clearing subtasks.
        unless tracker_ids.include?(tracker[owner_id])
          result.skipped_owner_tracker += 1
          next
        end

        # The subtask cannot hold the field -> writing one would be invisible data.
        unless tracker_ids.include?(tracker[id])
          result.skipped_subtask_tracker += 1
          next
        end

        if closed[id] && !include_closed
          result.skipped_closed += 1
          next
        end
        result.closed_owners += 1 if closed[owner_id]

        row = { issue_id: id, owner_id: owner_id, row_id: values[id]&.first,
                from: have, to: want }
        want.empty? ? result.to_clear << row : result.to_set << row
      end

      report(result)
      apply!(result, cf_id) if apply
      result
    end

    private

    def load_values(cf_id)
      map = {}
      CustomValue.where(customized_type: 'Issue', custom_field_id: cf_id)
                 .pluck(:customized_id, :id, :value)
                 .each { |issue_id, row_id, value| map[issue_id] = [row_id, value] }
      map
    end

    def normalize(value)
      value.to_s.strip
    end

    def report(result)
      diverged = result.to_set.size + result.to_clear.size + result.skipped_closed +
                 result.skipped_subtask_tracker + result.skipped_owner_tracker

      log "Subtasks already matching their owner: #{result.already_ok} (nothing to do)"
      log "Subtasks whose date differs          : #{diverged}"
      log "  -> will set to the owner's date    : #{result.to_set.size}"
      log "  -> will clear (owner has none)     : #{result.to_clear.size}"
      log "  -> skipped, subtask is closed      : #{result.skipped_closed}"
      log "  -> skipped, subtask tracker has no field: #{result.skipped_subtask_tracker}"
      log "  -> skipped, owner tracker has no field : #{result.skipped_owner_tracker}"
      log "WILL CHANGE: #{result.to_set.size + result.to_clear.size} subtask(s)"
      log "  (of those, #{result.closed_owners} sit under a CLOSED top-level issue)" if result.closed_owners > 0

      (result.to_set + result.to_clear).first(10).each do |r|
        log "  ##{r[:issue_id]}: #{r[:from].inspect} -> #{r[:to].inspect} (owner ##{r[:owner_id]})"
      end
      total = result.to_set.size + result.to_clear.size
      log "  … and #{total - 10} more" if total > 10
    end

    def apply!(result, cf_id)
      rows = result.to_set + result.to_clear

      # Existing custom_values rows: one bulk UPDATE per distinct target value.
      rows.select { |r| r[:row_id] }.group_by { |r| r[:to] }.each do |value, group|
        group.each_slice(1000) do |slice|
          CustomValue.where(id: slice.map { |r| r[:row_id] }).update_all(value: value)
          result.applied += slice.size
          log "  updated #{slice.size} row(s) -> #{value.inspect}"
        end
      end

      # Missing rows: only worth creating when there is an actual value to store.
      missing = rows.reject { |r| r[:row_id] }.reject { |r| r[:to].empty? }
      missing.each_slice(500) do |slice|
        slice.each do |r|
          CustomValue.create!(customized_type: 'Issue', customized_id: r[:issue_id],
                              custom_field_id: cf_id, value: r[:to])
        end
        result.applied += slice.size
        log "  created #{slice.size} row(s)"
      end

      log "Applied #{result.applied} change(s)."
    end

    def log(message)
      puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] [RedmineFinalDate::SubtaskSync] #{message}"
    end
  end
end
