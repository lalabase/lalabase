import { Controller } from "@hotwired/stimulus"

// Country-driven field behaviour on the billing form
// (doc/billing_stammdaten_plan.md §9).
//
// Every list arrives as a value from Accounts::BillingRules and the countries
// gem — none of them is restated here. A copy in JavaScript would be a second
// place to maintain a rule that is a tax statement (E11), and the two would
// drift the first time a country changes sides.
//
// Visibility only. The binding decision is the server validation in the
// :billing context; this controller decides what is worth showing.
export default class extends Controller {
  static targets = [
    "country", "regionBlock", "regionField",
    "vatBlock", "vatField", "vatRequiredMarker", "vatRequiredHint"
  ]

  static values = {
    regionCountries: Array,
    vatOfferedCountries: Array,
    vatRequiredCountries: Array,
    subdivisions: Object,
    blankOption: String
  }

  connect() {
    // Sync only — the server already rendered the subdivision list for the
    // stored country, so rebuilding it here would throw the saved value away
    // on every page load.
    this.sync()
  }

  countryChanged() {
    this.rebuildRegionOptions()
    this.sync()
  }

  sync() {
    const country = this.country

    this.toggleBlock(this.regionBlockTarget, this.regionFieldTarget,
                     this.regionCountriesValue.includes(country))

    const vatOffered = this.vatOfferedCountriesValue.includes(country)
    this.toggleBlock(this.vatBlockTarget, this.vatFieldTarget, vatOffered)

    // The asterisk and the explanation travel together: the field is offered
    // for GB and CH too, where it is optional, so the marker alone would
    // silently claim otherwise.
    const vatRequired = vatOffered && this.vatRequiredCountriesValue.includes(country)
    this.vatRequiredMarkerTarget.classList.toggle("hidden", !vatRequired)
    this.vatRequiredHintTarget.classList.toggle("hidden", !vatRequired)
  }

  // Hidden means "does not apply to this country", so the field must not carry
  // a leftover value into the request either: a New York state on a German
  // address, or a French VAT ID under a US one, would be stored invisibly and
  // could never be corrected through this form.
  toggleBlock(block, field, shown) {
    block.classList.toggle("hidden", !shown)
    if (!shown) field.value = ""
  }

  rebuildRegionOptions() {
    const options = this.subdivisionsValue[this.country] || []

    this.regionFieldTarget.replaceChildren(
      new Option(this.blankOptionValue, ""),
      ...options.map(([label, code]) => new Option(label, code))
    )
  }

  get country() {
    return this.countryTarget.value
  }
}
