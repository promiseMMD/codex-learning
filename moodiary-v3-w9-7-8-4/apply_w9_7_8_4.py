"""W9.7.8.4: reject incomplete Nutstore WebDAV directory listings.

No remote deletes, guesses at pagination, or silent incomplete inventories.
Run after the exact W9.7.8.3 Rust overlay.
"""
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
target = root / "packages/foundation/fast_core/rust/src/sync/webdav.rs"
data = target.read_text(encoding="utf-8")

def change(old, new):
    global data
    if data.count(old) != 1:
        raise SystemExit("W9.7.8.4 patch anchor mismatch: " + old[:100])
    data = data.replace(old, new, 1)

change("fn root_prefix(base: &url::Url, root: &str) -> String {",
'''/// Raw entries are counted before missing hrefs can be filtered away.
/// Only an intact response may become a remote inventory.
fn checked_webdav_page(base: &url::Url, body: &str, path: &str) -> Result<Vec<(String, bool)>> {
    let raw_entries = xml_elements(body, "response").len();
    if nutstore_directory_page_boundary(base, raw_entries) {
        return Err(tagged(
            "server",
            format!("Nutstore PROPFIND listing for {path} may be truncated at 750 entries; aborting"),
        ));
    }
    let entries = parse_multistatus(body);
    if base.host_str().is_some_and(|h| h.eq_ignore_ascii_case("dav.jianguoyun.com"))
        && (xml_elements(body, "multistatus").len() != 1
            || raw_entries == 0
            || entries.len() != raw_entries)
    {
        return Err(tagged(
            "server",
            format!("Nutstore PROPFIND listing for {path} has missing or malformed XML entries; aborting"),
        ));
    }
    Ok(entries)
}

fn root_prefix(base: &url::Url, root: &str) -> String {''')

change('''            if status == 404 {
                continue;
            }''',
'''            if status == 404 {
                if !dir.is_empty() {
                    return Err(tagged(
                        "server",
                        format!("WebDAV directory {path} disappeared during recursive listing; aborting incomplete snapshot"),
                    ));
                }
                // An absent root is valid for a newly configured account.
                continue;
            }''')

change('''            let responses = parse_multistatus(&body);
            if nutstore_directory_page_boundary(&self.base, responses.len()) {
                return Err(tagged(
                    "server",
                    format!("Nutstore PROPFIND listing for {path} may be truncated at 750 entries; refuse to treat it as a complete directory"),
                ));
            }''',
'''            let responses = checked_webdav_page(&self.base, &body, &path)?;''')

change('''                let Some(rel) = href_to_rel(&self.base, &prefix, &href) else {
                    continue;
                };''',
'''                let Some(rel) = href_to_rel(&self.base, &prefix, &href) else {
                    if self.base.host_str().is_some_and(|h| h.eq_ignore_ascii_case("dav.jianguoyun.com")) {
                        return Err(tagged(
                            "server",
                            format!("Nutstore PROPFIND listing for {path} contains an out-of-root href; aborting"),
                        ));
                    }
                    continue;
                };''')

change('''    #[test]
    fn nutstore_directory_page_boundary_is_checked_per_propfind() {''',
'''    #[test]
    fn nutstore_checked_page_counts_raw_responses() {
        let base: url::Url = "https://dav.jianguoyun.com/dav/".parse().unwrap();
        let entry = r#"<d:response><d:href>/dav/moodiary/</d:href></d:response>"#;
        let body = |n: usize| format!(
            r#"<d:multistatus xmlns:d="DAV:">{}</d:multistatus>"#,
            entry.repeat(n)
        );
        assert_eq!(checked_webdav_page(&base, &body(749), "moodiary/").unwrap().len(), 749);
        assert!(checked_webdav_page(&base, &body(750), "moodiary/").is_err());
        let malformed = format!(
            r#"<d:multistatus xmlns:d="DAV:">{}<d:response><d:propstat/></d:response></d:multistatus>"#,
            entry.repeat(748)
        );
        assert!(checked_webdav_page(&base, &malformed, "moodiary/").is_err());
    }

    #[test]
    fn nutstore_checked_page_rejects_missing_href_or_truncated_envelope() {
        let base: url::Url = "https://dav.jianguoyun.com/dav/".parse().unwrap();
        let valid = r#"<multistatus xmlns="DAV:"><response><href>/dav/moodiary/</href></response></multistatus>"#;
        let missing = r#"<multistatus xmlns="DAV:"><response><href>/dav/moodiary/</href></response><response><propstat/></response></multistatus>"#;
        let truncated = r#"<multistatus xmlns="DAV:"><response><href>/dav/moodiary/</href></response>"#;
        assert_eq!(checked_webdav_page(&base, valid, "moodiary/").unwrap().len(), 1);
        assert!(checked_webdav_page(&base, missing, "moodiary/").is_err());
        assert!(checked_webdav_page(&base, truncated, "moodiary/").is_err());
        let other: url::Url = "https://storage.example.org/dav/".parse().unwrap();
        assert!(checked_webdav_page(&other, missing, "moodiary/").is_ok());
    }

    #[tokio::test]
    async fn nutstore_child_404_must_not_be_interpreted_as_deleted() {
        let handler: HandlerFn = Arc::new(move |req: HttpServerRequest| {
            Box::pin(async move {
                match (req.method.as_str(), req.path.trim_end_matches('/')) {
                    ("PROPFIND", "/moodiary") => HttpServerResponse {
                        status: 207,
                        headers: vec![],
                        body: br#"<multistatus xmlns="DAV:"><response><href>/moodiary/</href><propstat><prop><resourcetype><collection/></resourcetype></prop></propstat></response><response><href>/moodiary/child/</href><propstat><prop><resourcetype><collection/></resourcetype></prop></propstat></response></multistatus>"#.to_vec(),
                    },
                    _ => HttpServerResponse {
                        status: 404,
                        headers: vec![],
                        body: vec![],
                    },
                }
            })
        });
        let (mut server, client) = serve(handler, "child404").await;
        assert!(client.list_objects().await.is_err());
        server.stop();
    }

    #[test]
    fn nutstore_directory_page_boundary_is_checked_per_propfind() {''')

target.write_text(data, encoding="utf-8")
print("W9.7.8.4 Rust listing completeness patch applied")
