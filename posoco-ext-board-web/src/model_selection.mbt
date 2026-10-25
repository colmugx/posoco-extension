///|
/// Compact chip text. Inheritance is named as such and never disguised as a
/// slot, so a card cannot imply a pinned model when the ticket follows
/// `/model`.
fn model_chip_label(selection : @client.ClientModelSelection?) -> String {
  match selection {
    None => "Inherit"
    Some(selection) =>
      match selection.effort {
        Some(effort) => "\{selection.slot} · \{effort}"
        None => selection.slot
      }
  }
}

///|
/// Inherit and pinned read as different states: inheritance stays quiet, a
/// pinned slot carries weight, and a pinned slot the catalog no longer offers
/// warns instead of pretending it is still selectable.
fn model_chip_tone(
  catalog : ModelCatalog,
  selection : @client.ClientModelSelection?,
) -> String {
  match selection {
    None => "is-inherit"
    Some(selection) =>
      match catalog.find(selection.slot) {
        Some(_) => "is-pinned"
        // An empty catalog means the host sent no projection at all, so the
        // chip has nothing to compare against and must not warn.
        None => if catalog.models.is_empty() { "is-pinned" } else { "is-warn" }
      }
  }
}

///|
fn model_chip_title(
  catalog : ModelCatalog,
  selection : @client.ClientModelSelection?,
) -> String {
  match selection {
    None => "Inherit: this ticket follows the current Cetas model."
    Some(selection) =>
      match catalog.find(selection.slot) {
        None =>
          if catalog.models.is_empty() {
            "Pinned to \{selection.slot}. Later Cetas model changes do not apply."
          } else {
            "Pinned to \{selection.slot}, which the host catalog no longer offers."
          }
        Some(option) => {
          let effort = match selection.effort {
            Some(effort) => " · effort \{effort}"
            None => ""
          }
          "Pinned to \{model_option_label(option)}\{effort}. Later Cetas model changes do not apply."
        }
      }
  }
}

///|
/// One card/detail chip for the ticket's model. The chip is text, not a
/// control: changing the model happens in the detail picker. The label rides
/// in an inner span so a long slot truncates with an ellipsis — text-overflow
/// does not apply to the flex container itself.
fn model_chip(
  catalog : ModelCatalog,
  selection : @client.ClientModelSelection?,
) -> @html.Html {
  @html.span(
    class="chip model-chip \{model_chip_tone(catalog, selection)}",
    title=model_chip_title(catalog, selection),
    [@html.span(class="chip-text", model_chip_label(selection))],
  )
}

///|
/// One option in a model or effort `<select>`. Values stay stable slot/effort
/// ids so the wire never carries a display label.
priv struct ModelSelectOption {
  value : String
  label : String
  title : String
  selected : Bool
  disabled : Bool
}

///|
/// Render resolved options as native `<option>` elements. Keeping the data
/// separate lets tests assert values and selection without mounting a DOM.
fn model_select_html(options : Array[ModelSelectOption]) -> Array[@html.Html] {
  options.map(option => {
    @html.option(
      value=option.value,
      title=option.title,
      selected=option.selected,
      disabled=option.disabled,
      option.label,
    )
  })
}

///|
fn model_option_label(option : ModelOption) -> String {
  let name = if option.label == "" { option.id } else { option.label }
  if option.provider == "" {
    name
  } else {
    "\{name} · \{option.provider}"
  }
}

///|
/// The catalog projection carries more than the option text needs; surface the
/// context window and capabilities as an option hint instead of dropping them.
fn model_option_hint(option : ModelOption) -> String {
  let parts : Array[String] = []
  match option.context_window {
    Some(window) if window > 0L => parts.push("\{window / 1000L}k context")
    _ => ()
  }
  if !option.capabilities.is_empty() {
    parts.push(option.capabilities.join(", "))
  }
  parts.join(" · ")
}

///|
/// `Inherit current` comes first and is the clear option; catalog models keep
/// their stable slot id as the value. A pinned slot missing from the catalog
/// stays visible but disabled so the control still reflects ticket state.
fn model_slot_options(
  catalog : ModelCatalog,
  selection : @client.ClientModelSelection?,
) -> Array[ModelSelectOption] {
  let pinned = match selection {
    Some(selection) => Some(selection.slot)
    None => None
  }
  let options : Array[ModelSelectOption] = [
    {
      value: "",
      label: "Inherit current",
      title: "Follow the current Cetas model; later model changes apply to this ticket.",
      selected: pinned is None,
      disabled: false,
    },
  ]
  for option in catalog.models {
    options.push({
      value: option.id,
      label: model_option_label(option),
      title: model_option_hint(option),
      selected: pinned == Some(option.id),
      disabled: false,
    })
  }
  match pinned {
    Some(slot) =>
      match catalog.find(slot) {
        Some(_) => ()
        None =>
          options.push({
            value: slot,
            label: "\{slot} · unavailable",
            title: "The host catalog no longer offers this slot. Choose another model or inherit.",
            selected: true,
            disabled: true,
          })
      }
    None => ()
  }
  options
}

///|
/// Effort choices for the pinned model. `Auto/default` is the null effort the
/// host resolves from the slot's own default; an effort the slot no longer
/// advertises stays visible but disabled.
fn model_effort_options(
  option : ModelOption,
  effort : String?,
) -> Array[ModelSelectOption] {
  let options : Array[ModelSelectOption] = [
    {
      value: "",
      label: "Auto/default",
      title: match option.default_effort {
        Some(default) => "Use the slot default (\{default})."
        None => "Use the slot's own default effort."
      },
      selected: effort is None,
      disabled: false,
    },
  ]
  for value in option.efforts {
    options.push({
      value,
      label: value,
      title: "",
      selected: effort == Some(value),
      disabled: false,
    })
  }
  match effort {
    Some(value) =>
      if !option.efforts.contains(value) {
        options.push({
          value,
          label: "\{value} · unavailable",
          title: "This slot no longer advertises this effort.",
          selected: true,
          disabled: true,
        })
      }
    None => ()
  }
  options
}

///|
/// Resolve a slot `<select>` value: the empty value clears back to inherit,
/// anything else pins that slot with its default effort.
fn model_choice_from_slot(value : String) -> ModelChoice? {
  if value == "" {
    None
  } else {
    Some({ slot: value, effort: None, })
  }
}

///|
/// Resolve an effort `<select>` value for an already pinned slot. The empty
/// value is the explicit `Auto/default`, which the host resolves.
fn model_choice_with_effort(slot : String, value : String) -> ModelChoice {
  { slot, effort: if value == "" { None } else { Some(value) }, }
}

///|
/// Why the picker cannot change the model right now. Rendered next to the
/// controls, never only in a tooltip.
fn model_picker_blocked(model : Model, task_id : String) -> String? {
  let _ = task_id
  if !model.can_connect || !model.ticket_available {
    Some("The ticket runtime is unavailable; the model cannot be changed.")
  } else if model.ticket_sending {
    Some("Wait for the current ticket command to finish.")
  } else {
    None
  }
}

///|
/// Readable reason the picker is read-only when the host does not offer a
/// selectable catalog. The pinned model itself stays visible as a chip.
fn model_unavailable_note(selection : @client.ClientModelSelection?) -> String {
  match selection {
    Some(_) => "This host keeps the pinned model read-only."
    None =>
      "No per-ticket picker on this host; the ticket inherits the host model."
  }
}

///|
/// The ticket's model catalog; absence is an unavailable catalog, not an
/// empty selectable one.
fn ticket_model_catalog(model : Model) -> ModelCatalog {
  match model.tickets.model_selection {
    Some(catalog) => catalog
    None => ModelCatalog::unavailable()
  }
}
