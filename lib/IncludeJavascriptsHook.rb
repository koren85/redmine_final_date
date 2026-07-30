module RedmineFinalDate
  # The final date is owned by the parent issue, so it must not be editable —
  # nor even visible — on a subtask. Redmine offers no server-side way to hide a
  # single custom field for a subset of issues, so the field is removed from the
  # DOM client-side.
  class IncludeJavascriptsHook < Redmine::Hook::ViewListener
    # Hide the field on the issue edit/new form.
    def view_issues_form_details_bottom(context = {})
      custom_field_id = hidden_custom_field_id(context[:issue])
      return '' if custom_field_id.nil?

      javascript_tag <<~JS
        (function() {
          var fieldId = "issue_custom_field_values_#{custom_field_id}";

          function removeCustomField() {
            var element = document.getElementById(fieldId);
            if (!element) { return; }
            var row = element.closest("p");
            if (row && row.parentNode) { row.parentNode.removeChild(row); }
          }

          function start() {
            removeCustomField();
            // Redmine re-renders the form over AJAX (tracker/project change),
            // which brings the field back — so keep removing it.
            new MutationObserver(removeCustomField).observe(
              document.body, { childList: true, subtree: true }
            );
          }

          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", start);
          } else {
            start();
          }
        })();
      JS
    end

    # Hide the field on the issue show page.
    def view_issues_show_details_bottom(context = {})
      custom_field_id = hidden_custom_field_id(context[:issue])
      return '' if custom_field_id.nil?

      javascript_tag <<~JS
        (function() {
          function hideCustomField() {
            var attribute = document.querySelector(".cf_#{custom_field_id}.attribute");
            if (attribute) { attribute.style.display = "none"; }
          }

          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", hideCustomField);
          } else {
            hideCustomField();
          }
        })();
      JS
    end

    private

    # Returns the id of the custom field to hide, or nil when the issue owns its
    # final date, the plugin is unconfigured, or the configured field was deleted
    # or is not available on this issue.
    #
    # Anything with a parent gets the field hidden, at any depth — only the
    # top-level issue of a branch owns the final date. A mid-level issue with
    # children of its own is not an owner either.
    def hidden_custom_field_id(issue)
      return nil if issue.nil? || issue.parent_id.blank?

      custom_field = RedmineFinalDate::Settings.custom_field
      return nil if custom_field.nil?
      return nil unless issue.available_custom_fields.include?(custom_field)

      custom_field.id
    end
  end
end
