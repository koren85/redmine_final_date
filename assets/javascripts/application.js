document.addEventListener("DOMContentLoaded", function() {

    let customField = document.querySelector("#issue_custom_field_values_#{custom_field_id}");
    if (customField) {
        customField.closest("div").style.display = "none";
    }
});