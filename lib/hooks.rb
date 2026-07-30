module RedmineFinalDate
  # Renders the parent issue's final date at the bottom of a subtask page.
  # Redmine::Hook::ViewListener already mixes in the ActionView helpers and
  # ApplicationHelper (hence `l` and `format_date`), so nothing extra is needed.
  class Hooks < Redmine::Hook::ViewListener
    def view_layouts_base_html_head(context = {})
      stylesheet_link_tag 'custom_styles', plugin: 'redmine_final_date'
    end

    def view_issues_show_details_bottom(context = {})
      issue = context[:issue]

      # The date shown is the one that owns the branch — the top-level issue's,
      # at any nesting depth. A mid-level issue is not an owner.
      owner = RedmineFinalDate::Settings.owner_of(issue)
      return '' if owner.nil?

      final_date = RedmineFinalDate::Settings.final_date_for(owner)
      return '' if final_date.nil?

      css_class = final_date <= User.current.today ? 'rfd-date-past' : 'rfd-date-future'

      content_tag(:p,
                  h("#{l(:label_parent_final_date)}: ") +
                    content_tag(:span, format_date(final_date), class: css_class))
    end
  end
end
