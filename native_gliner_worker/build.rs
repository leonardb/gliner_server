use std::env;
use std::path::PathBuf;

fn main() {
    // Provide weak definition of __libc_single_threaded for glibc < 2.32 compatibility
    // This symbol was added in glibc 2.32, but older systems need it
    
    let out_dir = env::var("OUT_DIR").unwrap();
    let out_path = PathBuf::from(&out_dir);
    
    // Create a small C file with the weak symbol definition
    let c_code = r#"
// Weak definition of __libc_single_threaded for glibc < 2.32 compatibility
// This symbol was added in glibc 2.32. On older glibc versions, we provide
// a weak definition that defaults to 0 (multi-threaded).
int __libc_single_threaded __attribute__((weak)) = 0;
"#;

    let c_file = out_path.join("libc_compat.c");
    std::fs::write(&c_file, c_code).expect("Failed to write libc_compat.c");
    
    // Compile the C file
    cc::Build::new()
        .file(&c_file)
        .compile("libc_compat");
    
    println!("cargo:rustc-link-search=native={}", out_dir);
}
