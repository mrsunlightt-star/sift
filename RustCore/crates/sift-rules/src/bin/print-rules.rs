//! Prints the built-in rule table as the document the app ships.
//!
//! `Scripts/generate-rules.py` runs this and renders both
//! `Core/Resources/CleaningRules.json` and the Swift fallback table from what it
//! prints. Run it through that script rather than by hand: the script is what
//! keeps the checked-in copies in step with the table the scanner applies.

fn main() {
    print!("{}", sift_rules::shipped_rules_json());
}
