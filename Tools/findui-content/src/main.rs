fn main() {
    if let Err(error) = findui_content::run() {
        eprintln!("findui-content: {error}");
        std::process::exit(2);
    }
}
