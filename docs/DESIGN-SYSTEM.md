# Front-desk design system

The shared pieces for registration and scheduling screens.
Each one is an ERB partial in `app/views/lakeraven/ehr/shared/`, called through a helper in `app/helpers/lakeraven/ehr/components_helper.rb`, and styled by an `@utility` in `app/assets/tailwind/lakeraven_ehr/engine.css`.
No component gem (DESIGN-PRINCIPLES 9); the markup stays ERB (DESIGN-PRINCIPLES 10).

Use a piece when your screen has the thing it describes.
If you need a piece that isn't here, build it in your view the way these are built, and say so in your PR so it can be extracted.

## Who it is for

A clerk at a shared front-desk workstation, checking patients in and booking them between phone calls.

- **Dense.** One screen holds the whole task. Prefer a table to cards, and a row of fields to a column when they are read together (From, Through).
- **Keyboard first.** Every action is a real link, button or input in reading order. Focus is always visible (engine.css). No action only on hover or drag.
- **Shared.** The header says who is signed in; the next person has to see that. Don't keep a patient on screen after the task is done.
- **No clinical data where it isn't needed.** The front desk sees who the patient is (name, health record number, date of birth, sex) and their appointments. Not allergies, problems or notes. Use `patient_summary`, not the clinical patient banner.

## Components

### page_title

Sets `<title>`: the parts, most specific first, then the product name.

```erb
<% page_title "Book", @resource[:name] %>
<%# => "Book | Dental clinic | Lakeraven EHR" %>
```

Every page calls it. Never write the product name in a view: it is one setting (`Lakeraven::EHR.configuration.product_name`), and what it should say is open (an ADR, "product name in the chrome", is proposed).

### page_header

The page's one `<h1>`, a lede, and optional actions.
The lede is a string, or an array of sentences (one `<p>` each).

```erb
<%= page_header "Find a patient",
      "Search before registering, so nobody gets a second chart." do %>
  <%= link_to "Register a new patient", registration_new_patient_path %>
<% end %>
```

Locals: `title`, `lede`, `actions`.

### alert_box, flash_alert, form_errors

Messages.
`:error` interrupts (`role="alert"`); `:notice` waits its turn (`role="status"`).
Pass sentences; a block adds more (a list).

```erb
<%= flash_alert id: "clinic-alert" %>

<%= form_errors @booking,
      "The appointment was not booked.",
      id: "booking-errors" %>

<%= alert_box :notice, "Booked.", id: "booked" %>

<%= alert_box :error,
      "The hours were not changed.",
      "Move or cancel these appointments first.",
      id: "hours-conflicts" do %>
  <ul>...</ul>
<% end %>
```

`flash_alert` renders `flash[:alert]` when there is one, which is where a controller puts RPMS's refusal.
`form_errors` renders nothing when the record has no errors.
Locals: `_alert` takes `kind`, `messages`, `id`, `body`; `_form_errors` takes `record`, `summary`, `id`.

### form_field

A label, an optional hint and error, and the input you give it.
The block receives the aria attributes that tie the hint and error to the input; pass them on.

```erb
<%= form_field :dob, "Date of birth", form: f, hint: "As on their ID." do |aria| %>
  <%= f.date_field :dob,
        value: @registration.dob,
        required: true,
        aria: aria %>
<% end %>
```

The label's `for` is `<form object name>_<attribute>` (Rails' own input id), or the attribute alone with no `form:`. Pass `id:` when the input's id differs.
Locals: `field_id`, `label`, `hint`, `hint_id`, `error`, `error_id`, `input`.

### choice_list

Radio buttons in a `<fieldset>` with a `<legend>`.
Each radio sits inside its `<label>`, so the whole line is clickable.
A choice is `[value, label]` or `[value, label, data]`; the data hash goes on the label (`data-tribe="12"`), which is what tests select on.

```erb
<%= choice_list f,
      :sex,
      legend: "Sex",
      choices: [ [ "F", "Female" ], [ "M", "Male" ] ],
      selected: @registration.sex,
      inline: true %>
```

A block's content follows the choices (a "Show reasons" button).
Locals: `form`, `attribute`, `legend`, `choices`, `selected`, `inline`, `hint`, `error`, `before`, `after`.

### lookup_field

A choice found by searching RPMS (tribe, community, provider): a "starts with" box and a Find button that resubmits the form without validating it, then the matches as radio buttons.
A choice already made and not re-searched stays in a hidden field, and `chosen_text` says so.

```erb
<%= lookup_field f,
      :provider_ien,
      legend: "Visit provider",
      search: :provider_search,
      search_label: "Provider name starts with",
      find_label: "Find provider",
      find_url: scheduling_checkin_clinic_appointment_path(@resource[:id], @appointment[:id]),
      find_method: :get,
      choices: @providers.map { |p| [ p.ien, p.name, { provider: p.ien } ] },
      selected: @checkin.provider_ien,
      chosen_text: "Provider chosen." %>
```

Partials: `_lookup_search` (`search`, `search_label`, `find_label`, `find_url`, `find_method`) and `_lookup_chosen` (`form`, `attribute`, `selected`, `any_choices`, `chosen_text`, `empty_text`). A search in its own form (booking's patient search) renders `_lookup_chosen` inside a `choice_list` block.

### status_badge

A status in words, coloured by its key.
The words carry the meaning; the colour only repeats it.

```erb
<% status_key, status = appointment_status(appointment) %>
<td data-status="<%= status_key %>"><%= status_badge status_key, status %></td>
```

Keys with a colour: booked, scheduled, checked, checked in, no-show, cancelled, active, inactive, revoked, deceased, and for a registration item, error and warning. Any other key gets the plain badge; add a key to `STATUS_TONES` in the helper (classes are written out whole there so the Tailwind build keeps them).
Locals: `key`, `label`, `tone`.

### empty_state

What a list says when it has nothing: what is missing, then the next step if there is one.

```erb
<%= empty_state "No patient matches “#{@query}”.",
      id: "no-match" do %>
  <%= link_to "Register a new patient", registration_new_patient_path %>
<% end %>
```

Locals: `messages`, `id`, `action`.

### patient_summary

Who the front desk has open: health record number, date of birth, sex. The name is the page's heading.

```erb
<%= patient_summary @patient, id: "registration" %>
```

Locals: `patient` (a hash with `:mrn`, `:dob`, `:sex`), `id`.

### The clinical patient banner

On a clinical page (the chart, allergy entry, consents, screenings), the patient is shown by `shared/_patient_banner`: name, date of birth, age, sex, record number and allergies.
The layout renders it for every page with a patient open, so a page never names the patient itself (no "Patient #4" in the heading).
The chart is a self-contained page that styles the banner inline; everywhere else it is styled by the `banner`, `demoinfo` and `patient-banner__*` utilities in engine.css.
Change both together, so the patient looks the same on every page.

### entry-form, field-row, form-actions

A clinical entry form (allergy entry): `entry-form` on the `<form>`, one `<fieldset>` per group of fields, `field-row` around fields read together (two columns from `sm` up), and `form-actions` around the primary button and the way back.

### Buttons

Classes, not a helper:

- `button-primary`: the one action the form exists for (Register, Book, Check in). One per form.
- `button-secondary`: everything else (Find, Show, Previous week).

```erb
<%= f.submit "Book", class: "button-primary self-start" %>
```

A destructive action (Cancel the appointment) is still the form's primary; its words say what it does.

### Data tables

No partial: a table's columns differ too much. The rules:

- `class="data-table"`, and an `id` tests can select on.
- A `<caption>` (`sr-only` when the heading already says it).
- `<th scope="col">` for each column; an actions column gets `<span class="sr-only">Actions</span>`.
- A `data-` attribute per row naming its record (`data-dfn`, `data-appointment`), and `data-status` on the status cell.

## Copy

- **The clerk's words, not RPMS's.** "Health record number", not "HRN" or "chart #"; "Who cancelled", not "CANCELLED BY". Keep the FileMan name in an ERB comment beside the field: `<%# CURRENT COMMUNITY, PATIENT (9000001) field 1118. %>`.
- **Short sentences, one per line** in the template, for clean diffs.
- **Say what happened, then what to do next.** "The appointment was not booked." then why, then the next step. Never just "Error".
- **When RPMS says no, show RPMS's reason.** Put it in `flash[:alert]` (or `@rpms_refusal`) word for word; don't paraphrase it away.
- **When the outcome is unknown, say so and say what not to do.** "RPMS did not say whether the patient was registered. Do not register them again yet."
- **Optional fields say "(optional)"** in the label; required ones say nothing and carry `required`.
- **Dates** read `Feb 3, 2026`; times are 24-hour `14:30`.
- **No product name in screen text.** Which name belongs in the chrome is undecided.

## Accessibility checklist

Each piece above already does its part. A screen still needs:

- one `<h1>` (`page_header`) and a distinct `<title>` (`page_title`);
- every input labelled (`form_field`, `choice_list`); placeholders are not labels;
- related radios and checkboxes in a `<fieldset>` with a `<legend>`;
- errors announced (`role="alert"`) and next to the summary sentence;
- colour never the only signal;
- tab order that follows the task.
