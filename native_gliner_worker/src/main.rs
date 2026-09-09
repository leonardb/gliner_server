// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

use std::io::{self, Read, Write};
use std::fs;
use std::path::{Path, PathBuf};
use serde_json::{json, Value};
use regex::Regex;

use gliner::model::GLiNER;
use gliner::model::pipeline::span::SpanMode;
use gliner::model::params::Parameters;
use gliner::model::input::text::TextInput;
use orp::params::RuntimeParameters;

// Download URLs for model and tokenizer from HuggingFace
// Using the standard resolve endpoint with download parameter
const TOKENIZER_URL: &str = "https://huggingface.co/onnx-community/gliner_small-v2.1/raw/main/tokenizer.json";
const MODEL_URL: &str = "https://huggingface.co/onnx-community/gliner_small-v2.1/resolve/main/onnx/model.onnx";

// Helper: Get stable cache directory for model files
fn get_model_cache_dir() -> io::Result<PathBuf> {
    // Try to use XDG_CACHE_HOME on Linux/macOS, or $HOME/.cache
    if let Ok(cache_home) = std::env::var("XDG_CACHE_HOME") {
        let cache_dir = PathBuf::from(cache_home).join("gliner_worker");
        fs::create_dir_all(&cache_dir)?;
        return Ok(cache_dir);
    }

    // Fall back to $HOME/.cache/gliner_worker
    if let Ok(home) = std::env::var("HOME") {
        let cache_dir = PathBuf::from(home).join(".cache").join("gliner_worker");
        fs::create_dir_all(&cache_dir)?;
        return Ok(cache_dir);
    }

    // Windows fallback: %APPDATA%/gliner_worker
    if let Ok(appdata) = std::env::var("APPDATA") {
        let cache_dir = PathBuf::from(appdata).join("gliner_worker");
        fs::create_dir_all(&cache_dir)?;
        return Ok(cache_dir);
    }

    // Last resort: /tmp/gliner_worker
    let cache_dir = PathBuf::from("/tmp/gliner_worker");
    fs::create_dir_all(&cache_dir)?;
    Ok(cache_dir)
}

// Helper: Download model files if missing, store in stable cache directory
fn ensure_model_files() -> io::Result<(PathBuf, PathBuf)> {
    // Use stable cache directory instead of current working directory
    let model_dir = get_model_cache_dir()?;

    let tokenizer_path = model_dir.join("tokenizer.json");
    let model_path = model_dir.join("model.onnx");

    // Download tokenizer if not present
    if !tokenizer_path.exists() {
        eprintln!("Downloading tokenizer.json to {}...", tokenizer_path.display());
        match download_file(TOKENIZER_URL, &tokenizer_path) {
            Ok(_) => eprintln!("✓ Tokenizer downloaded successfully"),
            Err(e) => {
                eprintln!("✗ Failed to download tokenizer: {}", e);
                return Err(e);
            }
        }
    } else {
        eprintln!("✓ Using cached tokenizer: {}", tokenizer_path.display());
    }

    // Download model if not present
    if !model_path.exists() {
        eprintln!("Downloading model.onnx to {} (this may take several minutes)...", model_path.display());
        match download_file(MODEL_URL, &model_path) {
            Ok(_) => eprintln!("✓ Model downloaded successfully"),
            Err(e) => {
                eprintln!("✗ Failed to download model: {}", e);
                return Err(e);
            }
        }
    } else {
        eprintln!("✓ Using cached model: {}", model_path.display());
    }

    Ok((tokenizer_path, model_path))
}

// Helper: Download a file from URL and save to disk
fn download_file(url: &str, dest_path: &Path) -> io::Result<()> {
    eprintln!("Fetching: {}", url);
    
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(300)) // 5 minute timeout per file
        .redirect(reqwest::redirect::Policy::limited(10)) // Follow up to 10 redirects
        .build()
        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("Client creation failed: {}", e)))?;
    
    let mut response = client.get(url)
        .send()
        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("HTTP request failed: {}", e)))?;

    if !response.status().is_success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("HTTP error {}: {} - {}", response.status(), url, response.status().canonical_reason().unwrap_or("Unknown error"))
        ));
    }

    // Get total size for progress tracking
    let total_size = response.content_length().unwrap_or(0);
    
    if total_size > 0 {
        eprintln!("File size: {:.1} MB", total_size as f64 / 1_000_000.0);
    } else {
        eprintln!("Warning: Could not determine file size, download may take a while...");
    }
    
    // Create temporary file to write to
    let temp_path = dest_path.with_extension("tmp");
    let mut file = fs::File::create(&temp_path)?;

    // Download with progress reporting
    let mut downloaded = 0u64;
    let mut buffer = [0u8; 65536]; // Larger buffer for better performance
    let start_time = std::time::Instant::now();
    let mut last_progress_time = start_time;
    
    loop {
        match response.read(&mut buffer) {
            Ok(0) => break, // EOF
            Ok(n) => {
                file.write_all(&buffer[..n])?;
                downloaded += n as u64;
                
                let now = std::time::Instant::now();
                // Update progress every 0.5 seconds to avoid excessive output
                if now.duration_since(last_progress_time).as_millis() > 500 || downloaded == total_size {
                    last_progress_time = now;
                    
                    if total_size > 0 {
                        let percent = (downloaded * 100) / total_size;
                        let elapsed = start_time.elapsed().as_secs_f64();
                        let speed = if elapsed > 0.1 { (downloaded as f64 / elapsed) / 1_000_000.0 } else { 0.0 };
                        let remaining = if speed > 0.1 { (total_size - downloaded) as f64 / speed / 1_000_000.0 } else { 0.0 };
                        
                        eprint!("\r[{}%] {:.1}/{:.1} MB | {:.1} MB/s | ETA: {:.0}s      ", 
                                percent,
                                downloaded as f64 / 1_000_000.0,
                                total_size as f64 / 1_000_000.0,
                                speed,
                                remaining);
                    } else {
                        let elapsed = start_time.elapsed().as_secs_f64();
                        let speed = if elapsed > 0.1 { (downloaded as f64 / elapsed) / 1_000_000.0 } else { 0.0 };
                        eprint!("\r{:.1} MB downloaded | {:.1} MB/s      ", 
                                downloaded as f64 / 1_000_000.0,
                                speed);
                    }
                    let _ = io::stderr().flush();
                }
            }
            Err(e) => {
                let _ = fs::remove_file(&temp_path);
                return Err(io::Error::new(io::ErrorKind::Other, 
                    format!("Download interrupted: {}", e)));
            }
        }
    }
    eprintln!(); // newline after progress
    
    file.sync_all()?;
    drop(file);

    // Move temp file to final location
    fs::rename(&temp_path, dest_path)?;
    
    Ok(())
}

// Helper: Remove {{...}} segments from text
fn remove_exclusions(text: &str) -> String {
    let mut clean_text = String::new();
    let mut current_pos = 0;
    
    while current_pos < text.len() {
        if let Some(start) = text[current_pos..].find("{{") {
            let absolute_start = current_pos + start;
            // Add text before the marker
            clean_text.push_str(&text[current_pos..absolute_start]);
            
            if let Some(end) = text[absolute_start + 2..].find("}}") {
                let absolute_end = absolute_start + 2 + end;
                // Skip the {{...}} segment entirely
                current_pos = absolute_end + 2;
            } else {
                // No closing }}, treat {{ as literal
                clean_text.push_str("{{");
                current_pos = absolute_start + 2;
            }
        } else {
            // No more markers, add remaining text
            clean_text.push_str(&text[current_pos..]);
            break;
        }
    }
    
    clean_text
}

// Helper: Extract email addresses using regex and remove them from text
fn extract_and_remove_emails(text: &str) -> (Vec<Value>, String) {
    // Email regex pattern: simple but effective for common email formats
    let email_regex = Regex::new(
        r"[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*"
    ).unwrap();
    
    // Extract all emails
    let emails: Vec<Value> = email_regex.find_iter(text)
        .map(|mat| {
            json!({
                "text": mat.as_str(),
                "entity_type": "email",
                "score": 0.99  // Regex matches have high confidence
            })
        })
        .collect();
    
    // Remove all matched emails from text
    let cleaned_text = email_regex.replace_all(text, "").to_string();
    
    (emails, cleaned_text)
}

// Helper: Extract dates in various formats and remove them from text
fn extract_and_remove_dates(text: &str) -> (Vec<Value>, String) {
    // Date patterns:
    // - DD/MM/YYYY, MM/DD/YYYY, YYYY/MM/DD
    // - DD-MM-YYYY, MM-DD-YYYY, YYYY-MM-DD
    // - DD.MM.YYYY
    // - Short formats: MM/DD, DD/MM, MM-DD, DD-MM, MM.DD, DD.MM
    // - Month DD, YYYY or DD Month YYYY (e.g., "January 15, 2025" or "15 January 2025")
    // - MMM DD, YYYY or DD MMM YYYY (e.g., "Jan 15, 2025")
    let date_regex = Regex::new(
        r"(?:(?:0?[1-9]|[12]\d|3[01])[-/\.](?:0?[1-9]|1[0-2])(?:[-/\.](?:19|20)?\d{2})?)|(?:(?:19|20)\d{2}[-/](?:0?[1-9]|1[0-2])[-/](?:0?[1-9]|[12]\d|3[01]))|(?:(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(?:0?[1-9]|[12]\d|3[01]),?\s+(?:19|20)?\d{2})|(?:(?:0?[1-9]|[12]\d|3[01])\s+(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(?:19|20)?\d{2})"
    ).unwrap();
    
    // Extract all dates
    let dates: Vec<Value> = date_regex.find_iter(text)
        .map(|mat| {
            json!({
                "text": mat.as_str(),
                "entity_type": "date",
                "score": 0.95  // Regex matches have high confidence
            })
        })
        .collect();
    
    // Remove all matched dates from text
    let cleaned_text = date_regex.replace_all(text, "").to_string();
    
    (dates, cleaned_text)
}

// Helper: Extract month names and remove them from text
fn extract_and_remove_months(text: &str) -> (Vec<Value>, String) {
    // Month patterns: Full names and abbreviations
    let month_regex = Regex::new(
        r"\b(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\b"
    ).unwrap();
    
    // Extract all months
    let months: Vec<Value> = month_regex.find_iter(text)
        .map(|mat| {
            json!({
                "text": mat.as_str(),
                "entity_type": "month",
                "score": 0.95  // Regex matches have high confidence
            })
        })
        .collect();
    
    // Remove all matched months from text
    let cleaned_text = month_regex.replace_all(text, "").to_string();
    
    (months, cleaned_text)
}

// Helper: Extract dollar amounts and remove them from text
fn extract_and_remove_dollar_amounts(text: &str) -> (Vec<Value>, String) {
    // Dollar patterns:
    // - $100, $1,234.56, $0.99
    // - 100 dollars, 1,234.56 dollars
    // - $100K, $5M (thousands/millions)
    let dollar_regex = Regex::new(
        r"\$(?:\d{1,3}(?:,\d{3})*(?:\.\d{2})?|\d+(?:\.\d{2})?)\s*(?:[KMB])?|(?:\d{1,3}(?:,\d{3})*(?:\.\d{2})?|\d+(?:\.\d{2})?)\s+dollars?"
    ).unwrap();
    
    // Extract all dollar amounts
    let amounts: Vec<Value> = dollar_regex.find_iter(text)
        .map(|mat| {
            json!({
                "text": mat.as_str(),
                "entity_type": "dollar_amount",
                "score": 0.98  // Regex matches have high confidence
            })
        })
        .collect();
    
    // Remove all matched amounts from text
    let cleaned_text = dollar_regex.replace_all(text, "").to_string();
    
    (amounts, cleaned_text)
}

// Helper: Extract payment rates (hourly, daily, monthly) and remove them from text
fn extract_and_remove_rates(text: &str) -> (Vec<Value>, String) {
    // Payment rate patterns:
    // Hourly: $25/hour, $15/hr, $20 per hour, $25k/hour, hourly rate: $50/hour
    // Daily: $100/day, $150/d, $200 per day, $5k/day, daily rate: $100
    // Monthly: $2000/month, $3000/mo, $1500 per month, $25k/month, monthly rate: $2000
    // Supports K/M/B suffixes (case-insensitive) for thousands/millions/billions
    let rate_regex = Regex::new(
        r"(?:\$(?:\d{1,3}(?:,\d{3})*(?:\.\d{2})?|\d+(?:\.\d{2})?)|(?:\d{1,3}(?:,\d{3})*(?:\.\d{2})?|\d+(?:\.\d{2})?))\s*(?:[KMBkmb])?\s*(?:dollars?)?\s*(?:per|/)\s*(?:hour|hr|h|day|d|month|mo)|(?:hourly|daily|monthly)\s+rate\s*[:=]?\s*\$?(?:\d{1,3}(?:,\d{3})*(?:\.\d{2})?|\d+(?:\.\d{2})?)\s*(?:[KMBkmb])?"
    ).unwrap();
    
    // Extract all rates
    let rates: Vec<Value> = rate_regex.find_iter(text)
        .map(|mat| {
            json!({
                "text": mat.as_str(),
                "entity_type": "payment_rate",
                "score": 0.96  // Regex matches have high confidence
            })
        })
        .collect();
    
    // Remove all matched rates from text
    let cleaned_text = rate_regex.replace_all(text, "").to_string();
    
    (rates, cleaned_text)
}

fn main() -> io::Result<()> {
    eprintln!("GLiNER Erlang Port starting...");

    // Extract embedded model and tokenizer to cache on first run
    let (tokenizer_path, model_path) = match ensure_model_files() {
        Ok(paths) => {
            eprintln!("✓ Model files ready");
            paths
        }
        Err(e) => {
            eprintln!("✗ Failed to prepare model files: {}", e);
            eprintln!("Continuing anyway, will fail on first request if models are missing");
            // Return error - the port will close but Erlang supervisor will restart it
            return Err(e);
        }
    };

    // Initialize model (loaded once at startup)
    eprintln!("Loading GLiNER model...");
    let parameters = Parameters::default();
    let runtime_params = RuntimeParameters::default();
    
    let model = match GLiNER::<SpanMode>::new(
        parameters,
        runtime_params,
        tokenizer_path.to_str().expect("Invalid tokenizer path"),
        model_path.to_str().expect("Invalid model path"),
    ) {
        Ok(m) => {
            eprintln!("✓ GLiNER model loaded successfully");
            m
        }
        Err(e) => {
            eprintln!("✗ Failed to load GLiNER model: {}", e);
            return Err(io::Error::new(io::ErrorKind::Other, format!("Model loading failed: {}", e)));
        }
    };

    // Pre-allocate labels (email removed - extracted via regex)
    let labels = vec![
        "person",
        "location",
        "city",
        "state",
        "country",
        "zip code",
        "address",
        "organization",
    ];

    eprintln!("GLiNER Erlang Port ready and listening...");
    eprintln!("---");

    // Main loop: read requests, process, and write responses
    let mut stdin = io::stdin();
    let mut stdout = io::stdout();

    // Send READY message to Erlang side to signal startup is complete
    // Protocol: [IdSize:u8][Id:binary][ResponseSize:u16][Response:binary]
    let ready_msg = b"S";  // IdSize=1, Id="S" (Startup/Signal)
    let ready_response = b"READY";
    let _ = stdout.write_all(&[ready_msg.len() as u8]);  // IdSize
    let _ = stdout.write_all(ready_msg);                  // Id
    let _ = stdout.write_all(&(ready_response.len() as u16).to_be_bytes());  // ResponseSize (big-endian)
    let _ = stdout.write_all(ready_response);             // Response
    let _ = stdout.flush();
    eprintln!("✓ Sent READY signal to Erlang");

    loop {
        // Protocol: <<IdSize:u8, Id:binary, TextSize:u16, Text:binary>>
        
        // 1. Read IdSize (1 byte)
        let mut id_size_buf = [0u8; 1];
        match stdin.read_exact(&mut id_size_buf) {
            Ok(()) => {},
            Err(ref e) if e.kind() == io::ErrorKind::UnexpectedEof => {
                eprintln!("Port closed by Erlang");
                break;
            }
            Err(e) => {
                eprintln!("Error reading IdSize: {}", e);
                break;
            }
        }
        let id_size = id_size_buf[0] as usize;

        // 2. Read Id (IdSize bytes)
        let mut id_buf = vec![0u8; id_size];
        if stdin.read_exact(&mut id_buf).is_err() {
            break;
        }
        let id = String::from_utf8_lossy(&id_buf).into_owned();

        // 3. Read TextSize (2 bytes, big-endian)
        let mut text_size_buf = [0u8; 2];
        if stdin.read_exact(&mut text_size_buf).is_err() {
            break;
        }
        let text_size = u16::from_be_bytes(text_size_buf) as usize;

        // 4. Read Text (TextSize bytes)
        let mut text_buf = vec![0u8; text_size];
        if stdin.read_exact(&mut text_buf).is_err() {
            break;
        }
        let text = String::from_utf8_lossy(&text_buf).into_owned();

        // Process the request
        // Remove {{...}} segments from text
        let clean_text = remove_exclusions(&text);
        
        // Extract emails and remove them from text
        let (email_entities, text_without_emails) = extract_and_remove_emails(&clean_text);
        
        // Extract dates and remove them from text
        let (date_entities, text_without_dates) = extract_and_remove_dates(&text_without_emails);
        
        // Extract months and remove them from text
        let (month_entities, text_without_temporal) = extract_and_remove_months(&text_without_dates);
        
        // Extract payment rates and remove them from text
        let (rate_entities, text_without_rates) = extract_and_remove_rates(&text_without_temporal);
        
        // Extract dollar amounts and remove them from text
        let (dollar_entities, text_without_financial) = extract_and_remove_dollar_amounts(&text_without_rates);
        
        // Perform inference on text with all special entities removed
        let input = match TextInput::from_str(&[text_without_financial.as_str()], &labels) {
            Ok(inp) => inp,
            Err(e) => {
                eprintln!("Error preparing input: {}", e);
                // Send error response
                let error_response = json!({"error": "Failed to prepare input", "count": 0, "entities": []});
                let response_payload = error_response.to_string();
                let response_bytes = response_payload.as_bytes();
                let id_bytes = id.as_bytes();
                
                let _ = stdout.write_all(&[id_bytes.len() as u8]);
                let _ = stdout.write_all(id_bytes);
                let _ = stdout.write_all(&(response_bytes.len() as u16).to_be_bytes());
                let _ = stdout.write_all(response_bytes);
                let _ = stdout.flush();
                continue;
            }
        };
        
        let output = match model.inference(input) {
            Ok(out) => out,
            Err(e) => {
                eprintln!("Inference error: {}", e);
                // Send error response
                let error_response = json!({"error": "Inference failed", "count": 0, "entities": []});
                let response_payload = error_response.to_string();
                let response_bytes = response_payload.as_bytes();
                let id_bytes = id.as_bytes();
                
                let _ = stdout.write_all(&[id_bytes.len() as u8]);
                let _ = stdout.write_all(id_bytes);
                let _ = stdout.write_all(&(response_bytes.len() as u16).to_be_bytes());
                let _ = stdout.write_all(response_bytes);
                let _ = stdout.flush();
                continue;
            }
        };
        
        let mut entities: Vec<Value> = output.spans[0].iter()
            .map(|span| {
                json!({
                    "text": span.text(),
                    "entity_type": span.class(),
                    "score": span.probability()
                })
            })
            .collect();
        
        // Add extracted email entities to the results
        entities.extend(email_entities);
        
        // Add extracted date entities to the results
        entities.extend(date_entities);
        
        // Add extracted month entities to the results
        entities.extend(month_entities);
        
        // Add extracted payment rate entities to the results
        entities.extend(rate_entities);
        
        // Add extracted dollar amount entities to the results
        entities.extend(dollar_entities);

        let count = entities.len();

        // Build JSON response
        let response_json = json!({
            "entities": entities,
            "count": count
        });
        
        let response_payload = response_json.to_string();
        let response_bytes = response_payload.as_bytes();
        let id_bytes = id.as_bytes();

        // Write response using binary protocol
        // Protocol: <<IdSize:u8, Id:binary, ResponseSize:u16, Response:binary>>
        let _ = stdout.write_all(&[id_bytes.len() as u8]);
        let _ = stdout.write_all(id_bytes);
        let _ = stdout.write_all(&(response_bytes.len() as u16).to_be_bytes());
        let _ = stdout.write_all(response_bytes);
        let _ = stdout.flush();
    }

    eprintln!("---");
    eprintln!("GLiNER Erlang Port shutting down gracefully");
    
    Ok(())
}



