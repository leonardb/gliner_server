use regex::Regex;

fn main() {
    println!("Testing state codes regex patterns...\n");

    let state_regex = Regex::new(
        r"\b(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY)\b"
    ).unwrap();

    let test_cases = vec![
        ("John works in AZ", vec!["AZ"]),
        ("Live in CA and love it", vec!["CA"]),
        ("She lives in NY.", vec!["NY"]),
        ("He is from TX, and loves it", vec!["TX"]),
        ("Amazing place FL!", vec!["FL"]),
        ("Do you like WA?", vec!["WA"]),
        ("Location: CO: beautiful place", vec!["CO"]),
        ("Visited CA, then TX, finally FL", vec!["CA", "TX", "FL"]),
        ("CA is beautiful", vec!["CA"]),
        ("AZAZ", vec![]),  // Concatenated states without boundary should not match
        ("NY-based company", vec!["NY"]),
        ("The TEXASAZ border", vec![]),
    ];

    let mut passed = 0;
    let mut failed = 0;

    for (text, expected) in test_cases {
        let matches: Vec<&str> = state_regex.captures_iter(text)
            .map(|c| c.get(1).unwrap().as_str())
            .collect();
        
        let pass = matches == expected;
        let status = if pass { "✓ PASS" } else { "✗ FAIL" };
        
        println!("{} | Input: \"{}\"", status, text);
        println!("        Expected: {:?}", expected);
        println!("        Got:      {:?}", matches);
        
        if pass {
            passed += 1;
        } else {
            failed += 1;
        }
        println!();
    }

    println!("\n=== Summary ===");
    println!("Passed: {}", passed);
    println!("Failed: {}", failed);
    println!("Total:  {}", passed + failed);

    if failed > 0 {
        std::process::exit(1);
    }
}
