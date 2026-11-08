"""W9.7.8.3: fail closed on Nutstore per-directory PROPFIND truncation.

The server's 750-entry limit is per response, NOT the whole recursive tree.
No guessed page token is sent. Safe pagination remains future work.
"""
from pathlib import Path
import sys

root=Path(sys.argv[1]).resolve()
code=root/'packages/foundation/fast_core/rust/src/sync/webdav.rs'
text=code.read_text(encoding='utf-8')

def replace(old,new):
    global text
    if text.count(old)!=1:
        raise SystemExit('Rust WebDAV safety patch did not match: '+old[:90])
    text=text.replace(old,new,1)

replace('const OCTET_STREAM: &str = "application/octet-stream";',
'''const OCTET_STREAM: &str = "application/octet-stream";
const NUTSTORE_SINGLE_DIRECTORY_PAGE_LIMIT: usize = 750;

/// A listing limit applies to each Depth:1 PROPFIND response, not the
/// aggregate flattened key count across the whole remote archive.
/// Without a verified next-page cursor, a full response is NOT complete.
fn nutstore_directory_page_boundary(base: &url::Url, entries: usize) -> bool {
    base.host_str()
        .is_some_and(|host| host.eq_ignore_ascii_case("dav.jianguoyun.com"))
        && entries >= NUTSTORE_SINGLE_DIRECTORY_PAGE_LIMIT
}
''')
replace('''            let mut found_self = false;
            for (href, is_collection) in parse_multistatus(&body) {''',
'''            let responses = parse_multistatus(&body);
            if nutstore_directory_page_boundary(&self.base, responses.len()) {
                return Err(tagged(
                    "server",
                    format!("Nutstore PROPFIND listing for {path} may be truncated at 750 entries; refuse to treat it as a complete directory"),
                ));
            }
            let mut found_self = false;
            for (href, is_collection) in responses {''')
replace('''mod tests {
    use super::*;''',
'''mod tests {
    use super::*;

    #[test]
    fn nutstore_directory_page_boundary_is_checked_per_propfind() {
        let nutstore: url::Url = "https://dav.jianguoyun.com/dav/".parse().unwrap();
        let generic: url::Url = "https://storage.example.net/dav/".parse().unwrap();
        let lookalike: url::Url =
            "https://dav.jianguoyun.com.attacker.net/dav/".parse().unwrap();
        assert!(!nutstore_directory_page_boundary(&nutstore, 749));
        assert!(nutstore_directory_page_boundary(&nutstore, 750));
        assert!(nutstore_directory_page_boundary(&nutstore, 751));
        assert!(!nutstore_directory_page_boundary(&generic, 750));
        assert!(!nutstore_directory_page_boundary(&lookalike, 750));
    }
''')
code.write_text(text,encoding='utf-8')
print('W9.7.8.3 Rust WebDAV per-directory listing safety gate installed')
