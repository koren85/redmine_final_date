# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Plugin Overview

`redmine_final_date` is a Redmine plugin that:
1. Displays a parent issue's "final date" (from a configurable custom field) on subtask detail pages, color-coded red (past) or blue (future)
2. Hides that custom field from subtask edit/show forms via JavaScript injection
3. Validates that a subtask's `start_date` does not exceed the parent's final date on update

The plugin does not create its own database tables — it reads from Redmine's existing `custom_field_values`.

## Running Tests

Tests run from the **Redmine root**, not the plugin directory:

```bash
# All plugin tests
cd /Users/aleksandrcernaev/RubymineProjects/redmine-4.1.3-1
bundle exec rake redmine:plugins:test NAME=redmine_final_date

# Single test file
bundle exec ruby -I test plugins/redmine_final_date/test/unit/some_test.rb

# Single test by name
bundle exec ruby -I test plugins/redmine_final_date/test/unit/some_test.rb -n test_method_name
```

The plugin's `test/test_helper.rb` delegates to Redmine's root `test/test_helper.rb`.

## Key Files

| File | Purpose |
|------|---------|
| `init.rb` | Plugin registration, settings defaults (`custom_field_id`, `check_subtask`), eager-loads all `lib/**/*.rb` |
| `lib/hooks.rb` | `RedmineFinalDate::Hooks` — injects CSS and renders parent's final date label on subtask show page |
| `lib/IncludeJavascriptsHook.rb` | `IncludeJavascriptsHook` — injects JS to hide the custom field from subtask forms and show views |
| `lib/redmine_final_date/models/custom_validation_patch.rb` | Patches `Issue` model with `check_subtask_start_date` validation; also defines unused `parent_start_date` |
| `app/controllers/settings_controller.rb` | Admin-only controller for `GET/POST /settings` |
| `app/views/redmine_final_date/_settings.html.erb` | Settings form: custom field selector + check_subtask checkbox |
| `config/locales/ru.yml` | Primary locale (Russian); `en.yml` is a placeholder |

## Architecture

### Settings
Plugin settings are stored via `Setting.plugin_redmine_final_date` and accessed everywhere as:
```ruby
Setting.plugin_redmine_final_date['custom_field_id'].to_i
Setting.plugin_redmine_final_date['check_subtask']  # truthy string or empty
```
The settings partial is at `app/views/redmine_final_date/_settings.html.erb` (Redmine convention for plugin settings).

### Hook Registration
Both hook classes are auto-loaded from `lib/` at boot via `Dir[...].each { require_dependency }` in `init.rb`. They self-register by inheriting from `Redmine::Hook::ViewListener`.

`RedmineFinalDate::Hooks` handles display logic; `IncludeJavascriptsHook` handles JS injection. Both respond to the same hook point (`view_issues_show_details_bottom`) — Redmine calls all registered listeners.

### Issue Model Patch
`custom_validation_patch.rb` uses the classic Redmine module-include pattern:
- `CustomValidationPatch` defines the validation method
- `IssuePatch` includes it into `Issue`
- Applied at load time via `Issue.send(:include, IssuePatch)`

The `check_subtask` flag controls validation scope:
- Truthy → validate all subtasks on update
- Falsy → validate only when `start_date` changed

### Validation behavior
The validation runs `on: :update` only. It throws `:abort` (halts save) when `start_date > parent_final_date`. Error messages are in Russian.

## Development Notes

- The `_hide_custom_field.html.erb` view and `assets/javascripts/application.js` appear to be unused/legacy code
- Several blocks in `IncludeJavascriptsHook.rb` are wrapped in `=begin`/`=end` (commented out) including a `controller_issues_edit_before_save` hook
- The `parent_start_date` method in `custom_validation_patch.rb` is defined but not called
- No migrations exist — the plugin relies entirely on admin-configured Redmine custom fields
