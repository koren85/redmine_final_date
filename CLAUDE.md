# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Plugin Overview

`redmine_final_date` is a Redmine plugin built around one admin-configured date custom field — the "final date" (Итоговая дата). It does six things:

1. **Displays** a parent issue's final date at the bottom of a subtask page, colour-coded red (past) or blue (future).
2. **Hides** that custom field from subtask edit forms and show pages via injected JavaScript — the final date belongs to the parent, so subtasks must not edit it.
3. **Validates** on update that a subtask's `start_date` does not exceed its parent's final date.
4. **Bulk-updates** the final date on every issue matched by a saved `IssueQuery`, driven by a rake task meant to run from cron.
5. **Keeps every subtask's final date equal to its top-level issue's** on each save (2026-10-11, setting `sync_subtasks`).
6. **Refuses work on a branch whose final date has passed** (2026-10-11): an employee cannot save the top-level issue while it sits on an employee in a listed status (`overdue_guard`), nor create a subtask under it (`overdue_block_subtasks`).

Items 5 and 6 are **off by default** — a deploy changes nothing until an admin switches them on in the plugin settings.

The plugin has no migrations and no tables of its own — it reads and writes Redmine's existing `custom_values`.

## Running Tests

`test/unit/final_date_rules_test.rb` covers items 5 and 6 above (the display hook, the JS and `DateUpdater` have no tests). Tests run from the **Redmine root**, and on this machine only through the shared test-database lock — several sessions share `redmine_test`:

```bash
cd /Users/alexandr/RubymineProjects/redmine-4.1.3-1
RBENV_VERSION=2.6.10 plugins/redmine_agent_work/tools/rtest --exec /opt/homebrew/Cellar/rbenv/1.3.2/libexec/rbenv exec \
  bundle exec bin/rails test plugins/redmine_final_date/test/unit/final_date_rules_test.rb
```

The tests build their own date field and stub `Setting.plugin_redmine_final_date`; issues are prepared with nobody logged in, so the rules under test do not get in the way of building the fixture.

For quick manual verification against the dev database, `rails runner` is the practical tool:

```bash
RAILS_ENV=development bundle exec rails runner /path/to/script.rb
```

Beware: **defining a top-level `def try(...)` in a runner script silently overrides `Object#try`** and produces baffling `private method 'try' called` errors deep inside Redmine and other plugins.

## Key Files

| File | Purpose |
|------|---------|
| `init.rb` | Plugin registration, settings defaults, eager-loads `lib/*.rb` then `lib/redmine_final_date/**/*.rb` on every `to_prepare` |
| `lib/redmine_final_date/settings.rb` | `RedmineFinalDate::Settings` — the single accessor for plugin settings; merges defaults, parses dates, resolves the custom field |
| `lib/hooks.rb` | `RedmineFinalDate::Hooks` — loads the stylesheet and renders the parent's final date on the subtask show page |
| `lib/IncludeJavascriptsHook.rb` | `RedmineFinalDate::IncludeJavascriptsHook` — injects JS that removes the custom field from subtask forms and show views |
| `lib/redmine_final_date/models/custom_validation_patch.rb` | Patches `Issue`: the `check_subtask_start_date` validation, the two "date in the past" validations, and the before/after_save pair that keeps subtasks equal to the owner |
| `lib/redmine_final_date/subtask_mirror.rb` | `RedmineFinalDate::SubtaskMirror.push_down` — writes a date onto every descendant, straight into `custom_values` |
| `lib/redmine_final_date/subtask_sync.rb` | `RedmineFinalDate::SubtaskSync` — the one-off repair of branches that drifted before item 5 existed |
| `lib/redmine_final_date/date_updater.rb` | `RedmineFinalDate::DateUpdater` — the bulk update engine |
| `lib/tasks/update_final_dates.rake` | `redmine:final_date:update_dates` — cron entry point |
| `app/views/redmine_final_date/_settings.html.erb` | Settings form (Redmine convention for plugin settings partials) |
| `config/locales/ru.yml`, `en.yml` | Both kept in sync; Russian is the primary working locale |

There is **no** `config/routes.rb` and no plugin controller — settings are served entirely by Redmine's built-in `settings/plugin/:id` route and the partial above. A previous `RedmineFinalDate::SettingsController` plus `get/post 'settings'` routes were dead code (core routes win for `GET /settings`, and `POST /settings` reached core's `SettingsController`, which has no `update` action); they were removed.

## Architecture

### Settings — always read through `RedmineFinalDate::Settings`

Never call `Setting.plugin_redmine_final_date[...]` directly. Redmine stores plugin settings as **one serialized Hash and replaces the registered defaults wholesale** — the two are never merged (`Setting.find_or_default`). Any key the settings form does not post simply disappears after the first save, so settings added in a later version read as `nil` until an admin re-saves the form.

`Settings.all` layers the stored hash over `init.rb`'s defaults to compensate. On the live install the stored hash was literally `{"custom_field_id" => "81"}` — every automation setting depended on this merge. The settings partial reads through `Settings.all` too, so the form is pre-filled with defaults rather than blanks.

Two more consequences worth remembering:

- `check_box_tag` emits **no companion hidden field**, so an unchecked box posts nothing at all. `settings[check_subtask]` therefore needs an explicit `hidden_field_tag ... '0'` in front of it.
- Truthiness must be explicit. The old default for `check_subtask` was `''`, which is **truthy in Ruby**, so a fresh install validated every subtask regardless of the setting. Use `Settings.truthy?`, which accepts `1/true/yes/on`.

### Hook registration

Both hook classes inherit `Redmine::Hook::ViewListener` and self-register at load. `RedmineFinalDate::Hooks` handles display, `IncludeJavascriptsHook` handles JS injection; both respond to `view_issues_show_details_bottom` and Redmine calls every registered listener.

`ViewListener` already mixes in the ActionView helpers plus `ApplicationHelper` (and therefore `Redmine::I18n`), so `l`, `format_date`, `content_tag`, `javascript_tag` and `h` are all available without extra `include`s.

Both classes are namespaced under `RedmineFinalDate`. This matters: seven plugins in this installation define an `IssuePatch`, one of them (`redmine_issue_cause`) at top level. Sharing that constant is fragile even though it happens to work — Ruby fires the `included` hook even when the module is already in the ancestor chain, so each plugin's `class_eval` still runs.

### Issue model patch

`custom_validation_patch.rb` uses the classic Redmine pattern (`CustomValidationPatch` → `IssuePatch` → `Issue.send(:include, ...)`), both namespaced. `init.rb` re-requires the file on every `to_prepare`, i.e. on every request in development — that is safe because Active Support deduplicates callbacks sharing a symbol filter, so `validate :check_subtask_start_date` stays registered exactly once.

### Validation behaviour

Runs `on: :update` only, and bails out early when `parent_id` or `start_date` is blank, when the parent no longer exists, when the plugin is unconfigured, or when the stored field value does not parse as a date — each of these used to raise (`NoMethodError` / `ArgumentError`) and break issue saves outright.

The `check_subtask` flag controls scope: truthy → validate every subtask on update; falsy → validate only when `start_date` changed.

The failure is reported with `errors.add`, which is sufficient to halt the save. Note that the validation is registered last, so a `throw :abort` here would have no observable effect — don't reintroduce one.

### SubtaskSync — the one-off repair

`redmine:final_date:sync_subtasks` forces every subtask's final date to match the one owned by its top-level issue. It exists because the propagation workflow only fires when somebody edits the top-level issue, so branches that diverged earlier stay wrong until touched.

**Dry-run unless `APPLY=1`.** Writes go straight to `custom_values`, deliberately bypassing `Issue#save`: no journal (hence no mail and no Telegram), none of the ~30 active custom workflows fire, and `updated_on` is left alone. A data repair is not an event.

Three things it must keep doing:

- **Skip closed subtasks** (`INCLUDE_CLOSED=1` to override). Closed issues are finished work; rewriting their dates is churn. On this data that is more than half the candidates — 502 changes instead of 1088.
- **Skip subtasks whose tracker does not carry the field.** It applies to only 3 of 14 trackers here; writing a value elsewhere creates invisible orphan data.
- **Skip branches whose top-level issue's tracker cannot hold the field.** There is no authoritative value for such a branch, so clearing its subtasks would be a guess rather than a repair.

It is idempotent — a second run reports zero.

### Closed issues: why SubtaskSync and DateUpdater treat a closed owner differently

Deliberate asymmetry, do not "harmonise" it:

- **SubtaskSync copies** the owner's existing date and never modifies the owner. An open subtask under a *closed* top-level issue is still synced — that makes the branch consistent, which is the entire point.
- **DateUpdater changes** the owner's date. If the top-level issue is closed it is skipped, and therefore the whole branch must be skipped too: updating descendants while leaving the owner untouched would push them out of sync with the very issue they mirror.

### DateUpdater — not used in production

**The rake task is not scheduled on production and nobody uses it.** It was needed once and no longer is. It is kept working and maintained, but it is not load-bearing: roughly two thirds of the plugin's code, 8 of its 10 settings, and most of the settings form exist only for it. Only `custom_field_id` and `check_subtask` affect live behaviour.

What is actually live: the display hook, the JS field hiding, the `start_date` validation — and custom workflow #33, which propagates the date down a branch when someone edits the top-level issue. Until `sync_subtasks` is switched on, diagnose date-mismatch reports there first, not here; once it is on, the plugin does the propagation itself (next section) and #33 is redundant.

### Subtasks mirror the owner's date — the live mechanism (2026-10-11)

Workflow #33 fires only when somebody edits the top-level issue, runs a full `child.save` (and therefore every custom workflow) on each descendant, and can refuse the owner's save when one descendant fails validation. It does nothing for a subtask created later, moved to another parent, or edited through bulk edit / the API. On production that left 2 266 subtasks out of step with their owner (1 357 of them open, 173 created in the last 30 days) — the mismatch people see in issue lists.

With `sync_subtasks` on, the plugin holds the invariant itself, in `CustomValidationPatch`:

- **`before_save :rfd_take_owner_final_date`** — any issue that has a parent leaves its save carrying the owner's date, whatever it was saved with. That covers creation, a later save of a subtask that drifted, a move to another parent, and any attempt to set the date on the subtask (inert: the owner's value wins). It reads the owner through `Settings.owner_after_save`, which resolves `parent_issue_id` — Redmine copies the parent chosen in the form into `parent_id` only in its own `before_save`, so `parent_id` is stale during validation and nil on a new record. **`Settings.owner_of` still reads `parent_id` and is left for the older `start_date` validation and the display hooks**: switching it changed that validation's verdict on a move even with every new setting off (acceptance review, 2026-10-11), and "off by default" has to mean "exactly as before".
- **`after_save :rfd_push_final_date_down`** — when the date of an issue changed in this save, or the issue was moved, `SubtaskMirror.push_down` writes the owner's date onto all its descendants. For the owner itself the value comes from memory, not from the database: the owner's own `custom_values` row is written by another `after_save` (acts_as_customizable) and ordering must not matter.
- **Writes to descendants are silent** — straight to `custom_values`, like `SubtaskSync`: no journal (hence no mail, no Telegram), no custom workflows, `updated_on` untouched. A subtask does not own this date; mirroring it is not an event in the subtask's life.
- **The push runs inside its own savepoint** (`Issue.transaction(requires_new: true)`). A plain `rescue` is not enough: after a database error PostgreSQL refuses every further statement in the transaction, and the owner's own save would die with `PG::InFailedSqlTransaction`. With the savepoint only the mirroring is rolled back; the descendants catch up on their next save.
- **Closed descendants are included** here, unlike in the one-off repair's default: once the owner's date moves, a closed subtask still showing the old one is exactly the visible mismatch.
- **A branch whose owner's tracker cannot hold the field is left alone**, same as in `SubtaskSync` — there is no authoritative value to mirror.
- A subtask whose own save heals a drifted value gets an ordinary journal detail for the field if that save has a journal. After the one-off repair this is rare; on a move to another parent it is meaningful.

It coexists with workflow #33. On this installation #33 runs first (measured on the dev copy: custom workflows' `after_save` precedes the plugin's), saves as many descendants as it can through `child.save` — it stops at the first one that fails validation, which is one of the ways branches drifted — and the plugin then completes the rest silently.

**Do not disable #33 before looking at workflow #17 "Синхронизация с иркутском"** (one project). #17 sends the final date to an external system from a `before_save`, and on subtasks it fires only because #33 saves them. The plugin's silent write does not go through `Issue#save`, so without #33 a date change would stop reaching that system for subtasks. **Decided 2026-10-13: subtasks do not need to be sent there** — so #33 goes off as part of the production rollout, once `sync_subtasks` is on; #17 keeps sending the top-level issue's own date.

Two races the callbacks cannot close (reasoned, not reproduced): a subtask created while the owner's date change is still uncommitted reads the old date; a deadlock between the push and a concurrent subtask save rolls the push back. Both leave a subtask one step behind until its next save. A nightly `rake redmine:final_date:sync_subtasks APPLY=1 INCLUDE_CLOSED=1` is the cheap safety net.

Rollout order: deploy → `rake redmine:final_date:sync_subtasks` (report) → the same with `APPLY=1 INCLUDE_CLOSED=1` → switch `sync_subtasks` on → disable workflow #33 → (optional) the nightly rake.

### A final date in the past (2026-10-11)

The owner's rule: a final date must not be earlier than today, otherwise the branch can neither be started nor put into a plan (subtask dates may not exceed it). Customers do not edit the field (it is read-only for their roles); employees do — 2 212 edits on top-level issues in 90 days on production — so the refusal lands on someone who can fix it.

Three validations, all in `CustomValidationPatch`, all bound to **employees' own actions**:

- **`rfd_check_overdue_final_date`** (`overdue_guard`) — a top-level issue whose final date is before today cannot be saved when, *after the save*, its status is in `overdue_status_ids` **and** its assignee is an employee (a user in `staff_group_ids`, or one of those groups itself — list the department queue groups there too). Judged by what is being saved, so the very save that moves the date to today or later, **clears the date**, hands the issue to the customer, leaves it unassigned or takes it out of the listed statuses goes through. Clearing must stay possible — that was an explicit decision, do not "close the loophole".
- **`rfd_check_subtask_under_overdue_owner`** (`overdue_block_subtasks`) — no new subtask at any depth under such an issue, whatever the owner's status, and no moving an existing issue into the branch from outside (the same thing done in two steps). Existing subtasks are not affected, and a subtask may be moved around inside its own branch.
- **`rfd_check_overdue_date_stays_in_force`** (active when either rule above is on) — a date that has passed stops applying only when someone moves or clears it, never as a side effect. An issue that owns such a date cannot be put under a parent (with `sync_subtasks` on it would silently take the new owner's date; either way it would stop being judged as an owner) nor switched to a tracker or project that does not carry the field (the stored row would stay behind, out of sight). Refused whatever the status and the assignee; the same save may move or clear the date and then goes through. Added after the acceptance review showed both moves were a way around the first two rules.

What is deliberately **not** closed: moving a top-level issue whose date is *fine* under another parent changes its date to the new owner's without asking anyone for a reason — the change is recorded in the history as automatic. If that ever matters, it is a decision for the owner, not a bug to fix quietly.

Who is bound (`Settings.staff_actor?`): a logged-in user who is in `staff_group_ids`. Not bound: **administrators — never, even as members of those groups (the owner's decision, 2026-10-12: "an administrator is not an employee")**; customers; saves with nobody logged in (rake, background threads); the scenario engine and the dispatcher, recognised by their thread flags `:pb_scenario_execution` and `:nd_dispatcher_execution` — read as plain thread keys so this plugin depends on neither. Automation may therefore leave an overdue issue on an employee; the first employee to touch it is the one who has to deal with the date. Process buttons and wizard cascades are an employee's actions and are bound.

**Until `staff_group_ids` is filled in, neither rule applies to anyone** — "who is an employee" is the admin's call, not a default.

The reason for moving or setting the date is not this plugin's business: `redmine_master_forms` asks for it ("История полей задачи", field `cf_<id>` with «причина обязательна» and «и при постановке значения»).

Every new callback and validation rescues `StandardError` and logs: a failure here must never break an issue save.

Things to know before switching the rules on in production:

- **Automation that runs as a logged-in employee and sets no thread flag counts as that employee.** A REST integration using an employee's key is bound — right for a person, wrong for a robot; run robots under an administrator's account or with nobody logged in. `redmine_auto_closer` works as the first active administrator and is therefore not bound. Keep closing and waiting statuses out of `overdue_status_ids` all the same.
- **Process buttons can end half-done.** Cascades are non-fatal by design: a button on a subtask of an overdue branch changes that subtask, while its cascaded subtask is not created (a warning is shown); a cascade onto the overdue owner is skipped together with its comment. Copying an issue with subtasks into an overdue branch copies the issue without them.
- **Scale.** On the dev copy 1 203 open top-level issues have a date in the past (993 with subtasks); on production 408 are in working statuses, 360 of them waiting for the customer. The status list decides how many employees meet the refusal on day one.

Known limits, left as they are on purpose (second round of the acceptance review, 2026-10-11 — accepted with these noted):

- **Detaching a subtask from an overdue branch dead-ends in the form.** Once detached it is a top-level issue carrying the past date, the guard refuses it, and the subtask form has no date field to fix (the JS hides it). Fix the owner's date first, or change status/assignee in the same save. Two such detachments a year on the dev copy.
- **Moving an existing subtask out of an overdue branch is not refused.** Under a healthy issue it takes that owner's date and new subtasks can be created below it. The owner itself stays under the rules.
- **A tracker switched to one without the field before the date passes** keeps its stored row; once the date passes nothing judges the issue until it comes back to a tracker with the field — then the guard applies at once.
- `rfd_check_overdue_date_stays_in_force` does not look at status or assignee, so it also covers closed issues. A tracker or project change cannot be combined with clearing the date in one save (the field is already gone from the issue being saved): clear first, then change.

Tests cover the model. The same validations serve bulk edit, REST and the customer's form; those paths were exercised by the reviewer's probes only.

### DateUpdater

Two phases, deliberately: `build_plan` resolves every intended write into an ordered `issue_id => instruction` Hash, then `run` executes it. **Do not collapse these back into save-as-you-go.** The same issue is reachable from several filter matches within one tree, and saving during traversal wrote it more than once — duplicate journal entries and duplicate notifications. `add_to_plan` keeps one write per issue; a journalled entry (the root) always beats a silent one.

Other things the engine relies on:

- **`User.current` must be set before `query.issues`.** `Issue.visible` filters by `User.current`, which defaults to `User.anonymous` in a rake context — that returns zero issues.
- `save_issue` swaps `User.current` to the acting user around the whole save, not just the journal, because Redmine's save callbacks are permission-sensitive.
- `init_journal` must be called **before** `custom_field_values=` and before `save`, or the change is not journalled.
- Acting user resolution: global `acting_user_id` → the issue's responsible user field → first active admin.
- Date modes: `add_to_today` / `add_to_field` add N **working** days via `Redmine::Utils::DateCalculation` (honours `Setting.non_working_week_days`); `set_fixed` uses a literal date.
- `{{date}}` in the comment text is substituted with the new date as `%d.%m.%Y`.
- The run aborts up front when the custom field is unset or deleted — otherwise every save would be a no-op that still writes a journal entry.

### The core invariant: one date per branch, owned by the top-level issue

**A branch carries exactly one final date, and only the top-level issue owns it.**

"Parent" in this codebase means the **top of the branch**, nothing else. An issue that has a parent is *never* an owner — not even when it has children of its own. There is no such thing as a mid-level owner. Every descendant at every depth mirrors the top-level issue's value; blank at the top means blank everywhere below.

Consequences, and they are the whole design:

- The field is editable only on the top-level issue. `IncludeJavascriptsHook` hides it for anything with a `parent_id`, at any depth.
- Editing the date on a subtask must be **inert** — it must not propagate anywhere. Workflow #33's `@issue.parent_id.nil?` guard is what guarantees that; it is deliberate, do not "fix" it away.
- The display hook and the validation both resolve `RedmineFinalDate::Settings.owner_of(issue)` and read the date from there. Comparing against the *immediate* parent would be wrong: a mid-level issue's value is not authoritative even when it carries one.
- `owner_of` goes through `parent.root` rather than `issue.root_id`, so it stays correct while a branch is being re-parented — the new `parent_id` is the value being saved and that parent's own root is already stable.

`DateUpdater` climbs to `root_id` for every filtered issue and fans out over `root.descendants`. Matching a mid-level subtask therefore writes the owning top-level issue and its whole branch (logged explicitly when it happens), instead of leaving the branch half-updated. This installation has issues down to depth 4, and `children` — direct children only — silently skipped everything below the first level.

### Silent subtask updates

Subtask final dates are maintained **without a journal**: no history entry, no mail, no Telegram. Only the root gets a journal, carrying the `comment_text` comment, and it notifies normally.

The mechanism is simply *not* calling `init_journal` — Redmine's `create_journal` is guarded by `@current_journal`, so no journal is written at all. That is sufficient to silence every channel, because **both** notification paths hang off `Journal` creation:

- Redmine mail — `Journal#send_notification` (`after_create_commit`).
- `redmine_notifier` Telegram — `notifier_channel_notify_on_journal` (`after_create_commit`), which deliberately ignores `Journal#notify?` because it wants to cover rake/console paths too.

So `journal.notify = false` alone would **not** stop Telegram. If the root's write ever needs silencing as well, that is the case to handle carefully — a `notify = false` there would still push to Telegram.

### Validation behaviour, restated

`check_subtask_start_date` compares the subtask's `start_date` against the **branch owner's** final date. It bails out early when `parent_id` or `start_date` is blank, when the owner cannot be resolved, when the plugin is unconfigured, or when the stored value does not parse as a date — each of those used to raise and break issue saves outright.

## External dependencies

The settings form uses Select2 from the separate **`a_common_libs`** plugin. Both the asset tags and the JS initialisation are guarded (`Redmine::Plugin.installed?` / `$.fn.select2`) so the form degrades to plain selects instead of breaking when that plugin is absent.

`a_common_libs` also patches `custom_field_value` on customizable models (`acl/acts_as_customizable_patch.rb`) — keep it in mind when custom field reads behave unexpectedly.

## Development notes

- CSS classes are prefixed (`.rfd-date-past`, `.rfd-date-future`). The stylesheet loads on **every** page via `view_layouts_base_html_head`, so generic names like `.red` are not safe here.
- User-facing strings live in the locale files; do not hardcode Russian in Ruby. Dates shown to users go through `format_date`, which respects `Setting.date_format`.
- The JS in `IncludeJavascriptsHook` keeps a `MutationObserver` on `document.body` because Redmine re-renders the issue form over AJAX (tracker/project change) and brings the hidden field back.
- The cron command shown on the settings page is display-only; nothing schedules the rake task automatically.
