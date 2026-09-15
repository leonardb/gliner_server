use regex::Regex;

fn main() {
    let pattern = r"\b(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY)\b";
    let state_regex = Regex::new(pattern).unwrap();
    
    let test_cases = vec![
        ("I live in AZ", 1),
        ("I live in AZ.", 1),
        ("I live in AZ, near Phoenix", 1),
        ("Sunny in FL! Come visit", 1),
        ("Is it in NY? Yes it is", 1),
        ("Here in CA: the best state", 1),
        ("Born in TX, raised in FL, live in CA", 3),
        ("AZAZ", 0),
        ("AZ Arizona AZ", 2),  // Note: Arizona is not a state code
        ("I live in Arizona", 0),  // No state codes
    ];
    
    for (text, expected) in test_cases {
        let matches: Vec<_> = state_regex.captures_iter(text).collect();
        let count = matches.len();
        let status = if count == expected { "✓" } else { "✗" };
        println!("{} '{}': expected {}, got {}", status, text, expected, count);
        if count != expected {
            for m in matches {
                println!("  Matched: {:?}", m.get(1).map(|m| m.as_str()));
            }
        }
    }
}
