use regex::Regex;

fn main() {
    println!("Testing different boundary patterns...\n");

    // Pattern 1: Both boundaries
    let both = Regex::new(
        r"\b(NY|AZ)\b"
    ).unwrap();

    // Pattern 2: Left boundary only (for hyphen support)
    let left_only = Regex::new(
        r"\b(NY|AZ)"
    ).unwrap();

    // Pattern 3: Left boundary + negative lookahead for word chars (approximate lookahead)
    // This doesn't work in Rust regex, but let's note it

    let test_cases = vec![
        "NY-based",
        "AZAZ",
        "NY company",
        "works in AZ",
    ];

    for text in test_cases {
        let matches_both: Vec<&str> = both.captures_iter(text)
            .map(|c| c.get(1).unwrap().as_str())
            .collect();
        let matches_left: Vec<&str> = left_only.captures_iter(text)
            .map(|c| c.get(1).unwrap().as_str())
            .collect();

        println!("Text: \"{}\"", text);
        println!("  Both boundaries \\b..\\b:  {:?}", matches_both);
        println!("  Left only \\b...:          {:?}", matches_left);
        println!();
    }
}
