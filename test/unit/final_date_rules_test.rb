# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Two rules about the final date:
#
# * every subtask carries the date of its top-level issue (sync_subtasks);
# * an employee cannot save a top-level issue whose date has passed while it
#   sits on an employee in one of the listed statuses, nor create a subtask
#   under it (overdue_guard, overdue_block_subtasks).
class FinalDateRulesTest < ActiveSupport::TestCase
  include Redmine::I18n

  fixtures :projects, :users, :email_addresses, :user_preferences,
           :trackers, :projects_trackers, :issue_statuses, :enumerations,
           :workflows, :roles, :members, :member_roles, :enabled_modules,
           :groups_users

  NEW_STATUS = 1
  ASSIGNED_STATUS = 2
  RESOLVED_STATUS = 3
  CLOSED_STATUS = 5

  def setup
    @employee = User.find(2)   # member of project 1
    @colleague = User.find(3)  # member of project 1, added to the staff group
    @customer = User.find(4)   # not in the staff group
    Member.create!(project_id: 1, principal: @customer, role_ids: [2]) unless @customer.member_of?(Project.find(1))

    @staff = Group.generate!
    @staff.users << @employee
    @staff.users << @colleague

    # The field is attached to trackers 1 and 2 only: tracker 3 cannot hold it.
    @field = IssueCustomField.generate!(name: 'Final date (test)', field_format: 'date',
                                        is_for_all: true, tracker_ids: [1, 2])
    @settings = {
      'custom_field_id' => @field.id.to_s,
      'sync_subtasks' => '1',
      'overdue_guard' => '1',
      'overdue_block_subtasks' => '1',
      'overdue_status_ids' => ['', NEW_STATUS.to_s, ASSIGNED_STATUS.to_s],
      'staff_group_ids' => ['', @staff.id.to_s]
    }
    Setting.stubs(:plugin_redmine_final_date).returns(@settings)
    Setting.stubs(:plugin_redmine_issue_cause).returns(
      'allowed_groups' => [], 'allowed_status' => [], 'allowed_trackers' => []
    )
    Setting.stubs(:notified_events).returns([])
    User.current = nil
    @today = Date.today
  end

  def teardown
    User.current = nil
    Thread.current[:pb_scenario_execution] = nil
    Thread.current[:nd_dispatcher_execution] = nil
  end

  # --- subtasks mirror the owner's date ---------------------------------

  def test_new_subtask_takes_the_owner_date
    root = root_with_date(@today + 10)
    child = subtask_of(root)

    assert_equal (@today + 10).to_s, stored_date(child)
  end

  def test_new_subtask_two_levels_down_takes_the_top_level_date
    root = root_with_date(@today + 10)
    child = subtask_of(root)
    grandchild = subtask_of(child)

    assert_equal (@today + 10).to_s, stored_date(grandchild)
  end

  def test_changing_the_owner_date_reaches_every_descendant
    root = root_with_date(@today + 10)
    child = subtask_of(root)
    grandchild = subtask_of(child)

    set_date(root, @today + 20)

    assert_equal (@today + 20).to_s, stored_date(child)
    assert_equal (@today + 20).to_s, stored_date(grandchild)
  end

  def test_changing_the_owner_date_reaches_closed_subtasks
    root = root_with_date(@today + 10)
    child = subtask_of(root)
    child.update_columns(status_id: CLOSED_STATUS)

    set_date(root, @today + 20)

    assert_equal (@today + 20).to_s, stored_date(child)
  end

  def test_the_date_reaches_subtasks_without_a_journal_or_a_touch
    root = root_with_date(@today + 10)
    child = subtask_of(root)
    child.update_columns(updated_on: 3.days.ago)
    touched = child.reload.updated_on

    assert_no_difference -> { Journal.where(journalized_type: 'Issue', journalized_id: child.id).count } do
      set_date(root, @today + 20)
    end

    assert_equal touched.to_i, child.reload.updated_on.to_i
  end

  def test_clearing_the_owner_date_clears_the_subtasks
    root = root_with_date(@today + 10)
    child = subtask_of(root)

    set_date(root, nil)

    assert_equal '', stored_date(child)
  end

  def test_setting_a_date_on_a_subtask_is_inert
    root = root_with_date(@today + 10)
    child = subtask_of(root)

    set_date(child, @today + 99)

    assert_equal (@today + 10).to_s, stored_date(child)
    assert_equal (@today + 10).to_s, stored_date(root)
  end

  def test_a_subtask_that_drifted_is_put_right_on_its_next_save
    root = root_with_date(@today + 10)
    child = subtask_of(root)
    force_stored_date(child, @today + 3)

    child.reload.update!(subject: 'touched')

    assert_equal (@today + 10).to_s, stored_date(child)
  end

  def test_moving_a_branch_gives_it_the_new_owner_date
    old_root = root_with_date(@today + 10)
    new_root = root_with_date(@today + 30)
    child = subtask_of(old_root)
    grandchild = subtask_of(child)

    child.reload
    child.parent_issue_id = new_root.id
    child.save!

    assert_equal (@today + 30).to_s, stored_date(child)
    assert_equal (@today + 30).to_s, stored_date(grandchild)
  end

  def test_a_subtask_whose_tracker_has_no_field_gets_nothing
    root = root_with_date(@today + 10)
    child = subtask_of(root, tracker_id: 3)
    set_date(root, @today + 20)

    assert_equal 0, CustomValue.where(customized_type: 'Issue', customized_id: child.id,
                                      custom_field_id: @field.id).count
  end

  def test_a_branch_whose_owner_cannot_hold_the_field_is_left_alone
    root = Issue.generate!(project_id: 1, tracker_id: 3)
    child = subtask_of(root)
    force_stored_date(child, @today + 3)

    child.reload.update!(subject: 'touched')

    assert_equal (@today + 3).to_s, stored_date(child)
  end

  def test_nothing_is_mirrored_when_the_setting_is_off
    @settings['sync_subtasks'] = '0'
    root = root_with_date(@today + 10)
    child = subtask_of(root)
    set_date(root, @today + 20)

    assert_equal '', stored_date(child)
  end

  # --- a final date in the past: the top-level issue --------------------

  def test_an_employee_cannot_save_an_overdue_issue_held_by_an_employee
    root = overdue_root

    User.current = @employee
    root.subject = 'any change at all'

    assert_refused_as_overdue root
  end

  def test_an_employee_cannot_take_an_overdue_issue_to_a_listed_status
    root = overdue_root(status_id: RESOLVED_STATUS)

    User.current = @employee
    root.status_id = ASSIGNED_STATUS

    assert_refused_as_overdue root
  end

  def test_an_employee_cannot_assign_an_overdue_issue_to_an_employee
    root = overdue_root(assigned_to: @customer)

    User.current = @employee
    root.assigned_to = @colleague

    assert_refused_as_overdue root
  end

  def test_an_overdue_issue_can_be_handed_to_the_customer
    root = overdue_root

    User.current = @employee
    root.assigned_to = @customer

    assert root.save, root.errors.full_messages.join(', ')
  end

  def test_an_overdue_issue_can_be_left_unassigned
    root = overdue_root

    User.current = @employee
    root.assigned_to = nil

    assert root.save, root.errors.full_messages.join(', ')
  end

  def test_an_overdue_issue_can_be_saved_in_a_status_that_is_not_listed
    root = overdue_root

    User.current = @employee
    root.status_id = RESOLVED_STATUS

    assert root.save, root.errors.full_messages.join(', ')
  end

  def test_an_issue_assigned_to_a_staff_group_is_covered
    root = overdue_root(assigned_to: @customer)
    Member.create!(project_id: 1, principal: @staff, role_ids: [2])

    with_settings issue_group_assignment: '1' do
      User.current = @employee
      root.reload.assigned_to = @staff

      assert_refused_as_overdue root
    end
  end

  def test_moving_the_date_to_today_lets_the_save_through
    root = overdue_root

    User.current = @employee
    root.custom_field_values = { @field.id.to_s => @today.to_s }

    assert root.save, root.errors.full_messages.join(', ')
  end

  def test_clearing_the_date_lets_the_save_through
    root = overdue_root

    User.current = @employee
    root.custom_field_values = { @field.id.to_s => '' }

    assert root.save, root.errors.full_messages.join(', ')
    assert_equal '', stored_date(root)
  end

  def test_setting_a_past_date_is_refused
    root = Issue.generate!(project_id: 1, tracker_id: 1, status_id: ASSIGNED_STATUS, assigned_to: @colleague)

    User.current = @employee
    root.custom_field_values = { @field.id.to_s => (@today - 1).to_s }

    assert_refused_as_overdue root, @today - 1
  end

  def test_a_date_of_today_is_not_overdue
    root = overdue_root(date: @today)

    User.current = @employee
    root.subject = 'still fine today'

    assert root.save, root.errors.full_messages.join(', ')
  end

  # The owner's decision (2026-10-12): an administrator is not an employee.
  def test_an_administrator_is_not_stopped
    admin = User.find(1)
    root = overdue_root

    User.current = admin
    root.subject = 'admin edit'
    assert root.save, root.errors.full_messages.join(', ')

    child = Issue.new(project_id: 1, tracker_id: 1, author: admin, subject: 'child',
                      parent_issue_id: root.id)
    assert child.save, child.errors.full_messages.join(', ')
  end

  def test_an_administrator_is_not_stopped_even_as_a_member_of_an_employee_group
    admin = User.find(1)
    @staff.users << admin
    root = overdue_root
    other = Issue.generate!(project_id: 1, tracker_id: 1)

    User.current = admin
    root.parent_issue_id = other.id

    assert root.save, root.errors.full_messages.join(', ')
  end

  def test_the_customer_is_not_stopped
    root = overdue_root

    User.current = @customer
    root.subject = 'customer comment'

    assert root.save, root.errors.full_messages.join(', ')
  end

  def test_nobody_logged_in_is_not_stopped
    root = overdue_root

    User.current = nil
    root.subject = 'background job'

    assert root.save, root.errors.full_messages.join(', ')
  end

  def test_the_scenario_engine_and_the_dispatcher_are_not_stopped
    %i[pb_scenario_execution nd_dispatcher_execution].each do |flag|
      root = overdue_root
      User.current = @employee
      Thread.current[flag] = true
      root.subject = "saved under #{flag}"

      assert root.save, "#{flag}: #{root.errors.full_messages.join(', ')}"
    ensure
      Thread.current[flag] = nil
    end
  end

  def test_the_issue_guard_does_nothing_when_switched_off
    root = overdue_root
    @settings['overdue_guard'] = '0'

    User.current = @employee
    root.subject = 'guard is off'

    assert root.save, root.errors.full_messages.join(', ')
  end

  def test_neither_rule_applies_until_employee_groups_are_chosen
    root = overdue_root
    @settings['staff_group_ids'] = ['']

    User.current = @employee
    root.subject = 'no groups configured'
    assert root.save, root.errors.full_messages.join(', ')

    child = Issue.new(project_id: 1, tracker_id: 1, author: @employee, subject: 'child',
                      parent_issue_id: root.id)
    assert child.save, child.errors.full_messages.join(', ')
  end

  def test_a_subtask_is_not_judged_by_the_issue_guard
    root = overdue_root(assigned_to: @customer)
    child = subtask_of(root, assigned_to: @colleague, status_id: ASSIGNED_STATUS)

    User.current = @employee
    child.reload.subject = 'working on the subtask'

    assert child.save, child.errors.full_messages.join(', ')
  end

  # --- a final date in the past: new subtasks ----------------------------

  def test_an_employee_cannot_create_a_subtask_under_an_overdue_issue
    root = overdue_root(assigned_to: @customer, status_id: RESOLVED_STATUS)

    User.current = @employee
    child = Issue.new(project_id: 1, tracker_id: 1, author: @employee, subject: 'child',
                      parent_issue_id: root.id)

    assert_refused_as_subtask child, root
  end

  def test_an_employee_cannot_create_a_subtask_deeper_in_an_overdue_branch
    root = root_with_date(@today + 5)
    middle = subtask_of(root)
    make_overdue(root)

    User.current = @employee
    child = Issue.new(project_id: 1, tracker_id: 1, author: @employee, subject: 'grandchild',
                      parent_issue_id: middle.id)

    assert_refused_as_subtask child, root
  end

  def test_an_employee_cannot_move_an_issue_under_an_overdue_one
    root = overdue_root(assigned_to: @customer)
    loose = Issue.generate!(project_id: 1, tracker_id: 1)

    User.current = @employee
    loose.reload.parent_issue_id = root.id

    assert_refused_as_subtask loose, root
  end

  def test_an_existing_subtask_of_an_overdue_issue_can_still_be_saved
    root = root_with_date(@today + 5)
    child = subtask_of(root)
    make_overdue(root)

    User.current = @employee
    child.reload.subject = 'existing subtask'

    assert child.save, child.errors.full_messages.join(', ')
  end

  def test_a_subtask_can_be_created_when_the_date_is_fine_or_absent
    User.current = @employee

    [root_with_date(@today), Issue.generate!(project_id: 1, tracker_id: 1)].each do |root|
      child = Issue.new(project_id: 1, tracker_id: 1, author: @employee, subject: 'child',
                        parent_issue_id: root.id)
      assert child.save, child.errors.full_messages.join(', ')
    end
  end

  def test_automation_can_create_a_subtask_under_an_overdue_issue
    root = overdue_root(assigned_to: @customer)

    User.current = nil
    child = Issue.new(project_id: 1, tracker_id: 1, author: @employee, subject: 'child',
                      parent_issue_id: root.id)

    assert child.save, child.errors.full_messages.join(', ')
  end

  def test_the_subtask_rule_does_nothing_when_switched_off
    root = overdue_root(assigned_to: @customer)
    @settings['overdue_block_subtasks'] = '0'

    User.current = @employee
    child = Issue.new(project_id: 1, tracker_id: 1, author: @employee, subject: 'child',
                      parent_issue_id: root.id)

    assert child.save, child.errors.full_messages.join(', ')
  end

  # --- the ways out are only the listed ones (acceptance review) ---------

  def test_an_overdue_issue_cannot_get_out_by_becoming_a_subtask
    root = overdue_root
    other = Issue.generate!(project_id: 1, tracker_id: 1)

    User.current = @employee
    root.parent_issue_id = other.id

    assert_refused_as_overdue root
    assert_equal (@today - 3).to_s, stored_date(root)
  end

  def test_an_overdue_issue_cannot_get_out_by_becoming_a_subtask_with_mirroring_off
    @settings['sync_subtasks'] = '0'
    root = overdue_root
    other = Issue.generate!(project_id: 1, tracker_id: 1)

    User.current = @employee
    root.parent_issue_id = other.id

    assert_refused_as_overdue root
  end

  def test_an_overdue_issue_cannot_get_out_by_dropping_the_field_with_its_tracker
    root = overdue_root

    User.current = @employee
    root.tracker_id = 3

    assert_refused_as_overdue root
  end

  def test_an_issue_whose_tracker_never_had_the_field_is_not_judged_by_a_leftover_row
    root = Issue.generate!(project_id: 1, tracker_id: 3, status_id: ASSIGNED_STATUS, assigned_to: @colleague)
    force_stored_date(root, @today - 30)

    User.current = @employee
    root.reload.subject = 'no field on this tracker'

    assert root.save, root.errors.full_messages.join(', ')
  end

  # Not on an employee, so the guard itself would let the save through — but
  # the move would quietly replace the overdue date with the new owner's.
  def test_an_overdue_issue_held_by_the_customer_cannot_become_a_subtask_either
    root = overdue_root(assigned_to: @customer, status_id: RESOLVED_STATUS)
    other = root_with_date(@today + 7)

    User.current = @employee
    root.parent_issue_id = other.id

    assert_refused_as_overdue root
    assert_equal (@today - 3).to_s, stored_date(root)
  end

  def test_an_overdue_issue_held_by_the_customer_cannot_drop_the_field_either
    root = overdue_root(assigned_to: @customer, status_id: RESOLVED_STATUS)

    User.current = @employee
    root.tracker_id = 3

    assert_refused_as_overdue root
  end

  def test_the_same_save_may_clear_the_date_and_make_the_issue_a_subtask
    root = overdue_root
    other = root_with_date(@today + 7)

    User.current = @employee
    root.custom_field_values = { @field.id.to_s => '' }
    root.parent_issue_id = other.id

    assert root.save, root.errors.full_messages.join(', ')
    assert_equal (@today + 7).to_s, stored_date(root)
  end

  def test_an_issue_whose_date_is_fine_can_be_moved_under_a_parent
    root = root_with_date(@today + 2)
    other = root_with_date(@today + 7)

    User.current = @employee
    root.reload.parent_issue_id = other.id

    assert root.save, root.errors.full_messages.join(', ')
    assert_equal (@today + 7).to_s, stored_date(root)
  end

  def test_automation_and_the_customer_may_move_an_overdue_issue
    [nil, @customer].each do |actor|
      root = overdue_root(assigned_to: @customer, status_id: RESOLVED_STATUS)
      other = Issue.generate!(project_id: 1, tracker_id: 1)

      User.current = actor
      root.parent_issue_id = other.id

      assert root.save, "#{actor.inspect}: #{root.errors.full_messages.join(', ')}"
    end
  end

  def test_moving_and_dropping_are_not_judged_when_both_rules_are_off
    @settings['overdue_guard'] = '0'
    @settings['overdue_block_subtasks'] = '0'
    root = overdue_root
    other = Issue.generate!(project_id: 1, tracker_id: 1)

    User.current = @employee
    root.parent_issue_id = other.id

    assert root.save, root.errors.full_messages.join(', ')
  end

  def test_a_subtask_can_be_moved_inside_its_own_overdue_branch
    root = root_with_date(@today + 5)
    first = subtask_of(root)
    second = subtask_of(root)
    make_overdue(root)

    User.current = @employee
    second.reload.parent_issue_id = first.id

    assert second.save, second.errors.full_messages.join(', ')
  end

  # --- what must not change, and what must not break -----------------------

  def test_the_older_start_date_check_still_reads_the_stored_parent
    old_root = root_with_date(@today + 20)
    new_root = root_with_date(@today + 5)
    child = subtask_of(old_root)

    child.reload.parent_issue_id = new_root.id

    assert_equal old_root.id, RedmineFinalDate::Settings.owner_of(child).id
    assert_equal new_root.id, RedmineFinalDate::Settings.owner_after_save(child).id
  end

  def test_a_database_error_while_mirroring_does_not_break_the_save
    root = root_with_date(@today + 10)
    child = subtask_of(root)
    mirror = RedmineFinalDate::SubtaskMirror
    original = mirror.method(:push_down)
    mirror.define_singleton_method(:push_down) do |*|
      ActiveRecord::Base.connection.execute('SELECT 1 FROM rfd_no_such_table')
    end

    begin
      issue = Issue.find(root.id)
      issue.custom_field_values = { @field.id.to_s => (@today + 20).to_s }
      assert issue.save, issue.errors.full_messages.join(', ')
    ensure
      mirror.define_singleton_method(:push_down, original)
    end

    assert_equal (@today + 20).to_s, stored_date(root), 'the owner keeps its new date'
    assert_equal (@today + 10).to_s, stored_date(child), 'the subtask waits for its next save'
    child.reload.update!(subject: 'next save')
    assert_equal (@today + 20).to_s, stored_date(child)
  end

  private

  # Issues are prepared with nobody logged in, so the rules under test do not
  # get in the way of building the fixture.
  def root_with_date(date)
    root = Issue.generate!(project_id: 1, tracker_id: 1)
    set_date(root, date)
    root
  end

  def overdue_root(date: @today - 3, status_id: ASSIGNED_STATUS, assigned_to: @colleague)
    root = Issue.generate!(project_id: 1, tracker_id: 1, status_id: status_id, assigned_to: assigned_to)
    set_date(root, date)
    root.reload
  end

  def make_overdue(issue)
    set_date(issue, @today - 3)
  end

  def subtask_of(parent, attributes = {})
    Issue.generate!({ project_id: 1, tracker_id: 1, parent_issue_id: parent.id }.merge(attributes))
  end

  def set_date(issue, date)
    actor = User.current
    User.current = nil
    issue = Issue.find(issue.id)
    issue.custom_field_values = { @field.id.to_s => date.to_s }
    issue.save!
  ensure
    User.current = actor
  end

  # Writes the stored value behind the model's back — a subtask that drifted.
  def force_stored_date(issue, date)
    rows = CustomValue.where(customized_type: 'Issue', customized_id: issue.id, custom_field_id: @field.id)
    if rows.exists?
      rows.update_all(value: date.to_s)
    else
      CustomValue.create!(customized_type: 'Issue', customized_id: issue.id,
                          custom_field_id: @field.id, value: date.to_s)
    end
  end

  def assert_refused_as_overdue(issue, date = @today - 3)
    assert_not issue.save, 'the save was expected to be refused'
    assert_includes issue.errors[:base].join(' '), format_date(date)
  end

  def assert_refused_as_subtask(issue, owner)
    assert_not issue.save, 'the save was expected to be refused'
    assert_includes issue.errors[:base].join(' '), "##{owner.id}"
  end

  def stored_date(issue)
    CustomValue.where(customized_type: 'Issue', customized_id: issue.id, custom_field_id: @field.id)
               .pluck(:value).first.to_s
  end
end
