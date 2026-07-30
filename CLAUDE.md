# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Plugin Overview

`redmine_final_date` is a Redmine plugin built around one admin-configured date custom field — the "final date" (Итоговая дата). It does four independent things:

1. **Displays** a parent issue's final date at the bottom of a subtask page, colour-coded red (past) or blue (future).
2. **Hides** that custom field from subtask edit forms and show pages via injected JavaScript — the final date belongs to the parent, so subtasks must not edit it.
3. **Validates** on update that a subtask's `start_date` does not exceed its parent's final date.
4. **Bulk-updates** the final date on every issue matched by a saved `IssueQuery`, driven by a rake task meant to run from cron.

The plugin has no migrations and no tables of its own — it reads and writes Redmine's existing `custom_values`.

## Running Tests

There are currently no tests; `test/test_helper.rb` only delegates to Redmine's root helper. If you add any, they run from the **Redmine root**, not the plugin directory:

```bash
cd /Users/alexandr/RubymineProjects/redmine-4.1.3-1
bundle exec rake redmine:plugins:test NAME=redmine_final_date
bundle exec ruby -I test plugins/redmine_final_date/test/unit/some_test.rb -n test_method_name
```

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
| `lib/redmine_final_date/models/custom_validation_patch.rb` | Patches `Issue` with the `check_subtask_start_date` validation |
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

Two things it must keep doing:

- **Skip subtasks whose tracker does not carry the field.** It applies to only 3 of 14 trackers here; writing a value elsewhere creates invisible orphan data.
- **Skip branches whose top-level issue's tracker cannot hold the field.** There is no authoritative value for such a branch, so clearing its subtasks would be a guess rather than a repair.

It is idempotent — a second run reports zero.

### DateUpdater — not used in production

**The rake task is not scheduled on production and nobody uses it.** It was needed once and no longer is. It is kept working and maintained, but it is not load-bearing: roughly two thirds of the plugin's code, 8 of its 10 settings, and most of the settings form exist only for it. Only `custom_field_id` and `check_subtask` affect live behaviour.

What is actually live: the display hook, the JS field hiding, the `start_date` validation — and custom workflow #33, which propagates the date down a branch when someone edits the top-level issue. Diagnose date-mismatch reports there first, not here.

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
