module RedmineFinalDate
  # Copies a final date onto every descendant of an issue, the moment that date
  # changes. Together with the before_save in IssuePatch — which makes each
  # subtask take the owner's date on its own save — this is what keeps "one date
  # per branch" true without anyone having to edit the top-level issue first.
  #
  # Writes go straight to custom_values, for the same reasons SubtaskSync does
  # (see there): no journal and therefore no mail or Telegram, none of the
  # custom workflows fire on the descendants, updated_on is left alone. A
  # subtask does not own this date; mirroring it is not an event in the
  # subtask's life.
  #
  # Closed descendants are included, unlike in the one-off repair: once the
  # owner's date moves, a closed subtask showing the old one is exactly the
  # mismatch people see in issue lists.
  module SubtaskMirror
    module_function

    # @param issue [Issue] a saved issue whose descendants must carry +value+
    # @param field [CustomField] the final-date field
    # @param value [String] the date to store, '' to clear
    # @return [Integer] number of descendants changed
    def push_down(issue, field, value)
      ids = descendant_ids(issue, field)
      return 0 if ids.empty?

      value = value.to_s
      rows = CustomValue.where(customized_type: 'Issue', custom_field_id: field.id, customized_id: ids)
                        .pluck(:customized_id, :id, :value)

      stale = rows.select { |_issue_id, _row_id, stored| stored.to_s != value }.map { |row| row[1] }
      stale.each_slice(1000) { |slice| CustomValue.where(id: slice).update_all(value: value) }

      # A missing row already reads as "no date": only worth creating when
      # there is a date to store.
      missing = value.empty? ? [] : ids - rows.map(&:first)
      missing.each do |issue_id|
        CustomValue.create!(customized_type: 'Issue', customized_id: issue_id,
                            custom_field_id: field.id, value: value)
      end

      stale.size + missing.size
    end

    # Descendants that can hold the field. Positions are read back from the
    # database: after a move the in-memory lft/rgt of +issue+ are not reliable.
    def descendant_ids(issue, field)
      root_id, lft, rgt = Issue.where(id: issue.id).pluck(:root_id, :lft, :rgt).first
      return [] if root_id.nil? || lft.nil? || rgt.nil? || rgt - lft <= 1

      scope = Issue.where(root_id: root_id).where('lft > ? AND rgt < ?', lft, rgt)
                   .where(tracker_id: field.tracker_ids)
      scope = scope.where(project_id: field.project_ids) unless field.is_for_all?
      scope.pluck(:id)
    end
  end
end
