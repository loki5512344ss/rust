//! Refuses a candidate that adds or changes `unsafe` code.
//!
//! Fork addition. The upstream harness measures time and runs the tests, and
//! neither notices undefined behaviour: `get_unchecked` in place of an index
//! is the cheapest "optimization" there is, the tests still pass on the inputs
//! they happen to use, and the benchmark improves. So the candidate may not
//! introduce an `unsafe` region that the frozen baseline did not already
//! contain, token for token.
//!
//! The rule is deliberately about regions rather than about a list of
//! dangerous method names. A name list is always one name short, and anything
//! on such a list is only callable from inside an `unsafe` region anyway — so
//! "no new region, no changed region" covers every one of them, including
//! ones added to an `unsafe` block that already existed.
//!
//! The scan works on tokens, not on a parsed syntax tree, for one reason:
//! macro bodies. `syn` hands a macro invocation back as an opaque token
//! stream, so a tree visitor never sees `vec![unsafe { .. }]` or an `unsafe`
//! block inside `macro_rules!`. Tokens see both. Comments and string literals
//! are not tokens, so the word "unsafe" in prose never counts.
//!
//! What this does NOT catch, by construction: a safe edit that breaks the
//! invariant an *unchanged* `unsafe` region relies on (deleting the bounds
//! check in front of an existing `get_unchecked`). That needs a reviewer or
//! Miri; the gate narrows the hole, it does not close it.

use proc_macro2::{Delimiter, Group, TokenStream, TokenTree};
use std::collections::BTreeMap;

/// One `unsafe` region found in a source file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Region {
    /// The region's tokens rendered without the original whitespace, so that
    /// reformatting or moving a region does not make it look new.
    pub fingerprint: String,
    /// 1-based line of the `unsafe` keyword. 0 when the file could not be
    /// tokenized and the whole file stands in as one region.
    pub line: usize,
    /// A short human-readable label: `unsafe { .. }`, `unsafe fn name`, ...
    pub what: String,
}

/// A region the candidate has and the baseline does not.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Violation {
    pub file: String,
    pub line: usize,
    pub what: String,
}

/// Every `unsafe` region in `source`.
///
/// A region is the `unsafe` keyword plus everything up to and including the
/// first brace group after it — which is the whole of an `unsafe { }` block,
/// an `unsafe fn` with its body, an `unsafe impl`, an `unsafe trait` and an
/// `unsafe extern` block. Two shapes have no brace group and end earlier: a
/// body-less declaration (`unsafe fn f();`) ends at its `;`, and an unsafe
/// attribute (`#[unsafe(no_mangle)]`) is the keyword plus its parenthesized
/// argument.
///
/// Regions nested inside another region are part of the outer one and are not
/// reported separately: the outer fingerprint already covers them.
///
/// A file the tokenizer rejects is reported as ONE region covering the whole
/// file when its text contains the word `unsafe`, and as none otherwise. That
/// is conservative on purpose — a file that cannot be read cannot be cleared —
/// and costs nothing in practice, because rustc rejects such a file too.
pub fn regions(source: &str) -> Vec<Region> {
    match strip_shebang(source).parse::<TokenStream>() {
        Ok(tokens) => {
            let mut out = Vec::new();
            collect(tokens, &mut out);
            out
        }
        Err(_) if source.contains("unsafe") => vec![Region {
            fingerprint: source.to_string(),
            line: 0,
            what: "file that could not be tokenized and mentions unsafe".to_string(),
        }],
        Err(_) => Vec::new(),
    }
}

/// `#!/usr/bin/env ...` is valid on the first line of a Rust file but is not a
/// token; `#![attr]` on the first line is an attribute and must be kept.
fn strip_shebang(source: &str) -> &str {
    if source.starts_with("#!") && !source.starts_with("#![") {
        match source.find('\n') {
            Some(end) => &source[end..],
            None => "",
        }
    } else {
        source
    }
}

fn collect(tokens: TokenStream, out: &mut Vec<Region>) {
    let trees: Vec<TokenTree> = tokens.into_iter().collect();
    let mut i = 0;
    while i < trees.len() {
        match &trees[i] {
            TokenTree::Ident(ident) if ident == "unsafe" => {
                let end = region_end(&trees, i);
                out.push(Region {
                    fingerprint: fingerprint(&trees[i..end]),
                    line: ident.span().start().line,
                    what: describe(&trees[i..end]),
                });
                i = end;
            }
            TokenTree::Group(group) => {
                collect(group.stream(), out);
                i += 1;
            }
            _ => i += 1,
        }
    }
}

/// The index one past the last token of the region starting at `start`.
fn region_end(trees: &[TokenTree], start: usize) -> usize {
    // `#[unsafe(no_mangle)]`: the keyword is followed directly by parentheses.
    if let Some(TokenTree::Group(group)) = trees.get(start + 1) {
        if group.delimiter() == Delimiter::Parenthesis {
            return start + 2;
        }
    }
    for (offset, tree) in trees[start + 1..].iter().enumerate() {
        let index = start + 1 + offset;
        match tree {
            // A brace group followed by `>` or `,` is a const generic
            // argument in the signature (`Foo<{ N }>`), not the body.
            TokenTree::Group(group) if group.delimiter() == Delimiter::Brace => {
                let in_generics = matches!(
                    trees.get(index + 1),
                    Some(TokenTree::Punct(next)) if matches!(next.as_char(), '>' | ',')
                );
                if !in_generics {
                    return index + 1;
                }
            }
            TokenTree::Punct(punct) if punct.as_char() == ';' => return index + 1,
            _ => {}
        }
    }
    // `unsafe` with nothing closing it in this group — only reachable in
    // macro input, where the keyword can be passed around on its own. The
    // rest of the group is the most that could belong to it.
    trees.len()
}

/// Tokens joined by single spaces. `TokenTree`'s own `Display` spaces tokens
/// by where the lexer met them, which is exactly the formatting noise a
/// fingerprint must ignore; rendering leaf by leaf removes it.
fn fingerprint(trees: &[TokenTree]) -> String {
    let mut out = String::new();
    for tree in trees {
        render(tree, &mut out);
    }
    out
}

fn render(tree: &TokenTree, out: &mut String) {
    match tree {
        TokenTree::Group(group) => {
            // A doc comment reaches the token stream as `#[doc = "text"]`. Its
            // text is prose: rewording a `/// SAFETY:` note inside an unsafe
            // item must not read as a change to the code, so a doc attribute
            // is rendered without its text. Every other literal is part of
            // the code — `asm!("...")`, `#[link_name = "..."]`, an ABI name —
            // and is kept verbatim.
            if is_doc_attribute(group) {
                out.push_str("# [doc = \"\"] ");
                return;
            }
            let (open, close) = match group.delimiter() {
                Delimiter::Parenthesis => ("(", ")"),
                Delimiter::Brace => ("{", "}"),
                Delimiter::Bracket => ("[", "]"),
                Delimiter::None => ("", ""),
            };
            out.push_str(open);
            out.push(' ');
            for inner in group.stream() {
                render(&inner, out);
            }
            out.push_str(close);
            out.push(' ');
        }
        other => {
            out.push_str(&other.to_string());
            out.push(' ');
        }
    }
}

/// Whether `group` is a `#[doc = "..."]` (or `#![doc = "..."]`) attribute.
///
/// Only its *text* is normalized; the attribute itself still counts, so
/// rewording a doc comment inside an unsafe region does not change the
/// fingerprint.
fn is_doc_attribute(group: &Group) -> bool {
    if group.delimiter() != Delimiter::Bracket {
        return false;
    }
    let mut inner: Vec<TokenTree> = group.stream().into_iter().collect();
    if matches!(inner.first(), Some(TokenTree::Punct(p)) if p.as_char() == '!') {
        inner.remove(0);
    }
    matches!(inner.first(), Some(TokenTree::Ident(ident)) if ident == "doc")
        && matches!(inner.get(1), Some(TokenTree::Punct(p)) if p.as_char() == '=')
}

fn describe(trees: &[TokenTree]) -> String {
    let word = |index: usize| match trees.get(index) {
        Some(TokenTree::Ident(ident)) => Some(ident.to_string()),
        _ => None,
    };
    match trees.get(1) {
        Some(TokenTree::Group(group)) if group.delimiter() == Delimiter::Brace => {
            "unsafe { .. } block".to_string()
        }
        Some(TokenTree::Group(_)) => "unsafe attribute".to_string(),
        _ => match (word(1).as_deref(), word(2)) {
            (Some("fn"), Some(name)) => format!("unsafe fn {name}"),
            (Some("impl"), _) => "unsafe impl".to_string(),
            (Some("trait"), Some(name)) => format!("unsafe trait {name}"),
            (Some("extern"), _) => {
                // `unsafe extern "C" fn name` is a function, not a block.
                let name = trees.windows(2).find_map(|pair| match pair {
                    [TokenTree::Ident(keyword), TokenTree::Ident(name)] if keyword == "fn" => {
                        Some(name.to_string())
                    }
                    _ => None,
                });
                match (name, trees.last()) {
                    (Some(name), _) if !has_brace_before_fn(trees) => format!("unsafe fn {name}"),
                    _ => "unsafe extern block".to_string(),
                }
            }
            _ => "unsafe item".to_string(),
        },
    }
}

/// Whether a brace group opens before the first top-level `fn` keyword: true
/// for `unsafe extern "C" { fn c(); }` (the `fn` is inside the block, so it is
/// never seen at this level), false for `unsafe extern "C" fn name() {}`.
fn has_brace_before_fn(trees: &[TokenTree]) -> bool {
    for tree in trees {
        match tree {
            TokenTree::Ident(ident) if ident == "fn" => return false,
            TokenTree::Group(group) if group.delimiter() == Delimiter::Brace => return true,
            _ => {}
        }
    }
    true
}

/// Regions present in the candidate files and absent from the baseline files.
///
/// Both sides are `(repo-relative path, source text)` for the same set of
/// changed files. Regions are compared as a multiset across ALL the files
/// rather than file by file, so moving an untouched `unsafe` block from one
/// module to another is not a violation, while writing a second copy of an
/// existing one is.
pub fn added(baseline: &[(String, String)], candidate: &[(String, String)]) -> Vec<Violation> {
    let mut budget: BTreeMap<String, usize> = BTreeMap::new();
    for (_, source) in baseline {
        for region in regions(source) {
            *budget.entry(region.fingerprint).or_insert(0) += 1;
        }
    }
    let mut out = Vec::new();
    for (file, source) in candidate {
        for region in regions(source) {
            match budget.get_mut(&region.fingerprint) {
                Some(left) if *left > 0 => *left -= 1,
                _ => out.push(Violation {
                    file: file.clone(),
                    line: region.line,
                    what: region.what,
                }),
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one(source: &str) -> Vec<Region> {
        regions(source)
    }

    fn files(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(name, text)| (name.to_string(), text.to_string()))
            .collect()
    }

    #[test]
    fn safe_code_has_no_regions() {
        assert!(one("pub fn f(v: &[u8]) -> u8 { v[0] }").is_empty());
    }

    #[test]
    fn the_word_in_a_comment_or_a_string_is_not_a_region() {
        let source = "// unsafe is not used here\n/// unsafe in a doc comment\n\
                      pub fn f() -> &'static str { \"unsafe\" }";
        assert!(one(source).is_empty(), "{:?}", one(source));
    }

    #[test]
    fn every_shape_of_unsafe_is_found_and_labelled() {
        let source = "\
pub fn a(v: &[u8]) -> u8 { unsafe { *v.get_unchecked(0) } }
pub unsafe fn b() {}
unsafe impl Send for T {}
unsafe trait U {}
unsafe extern \"C\" { fn c(); }
#[unsafe(no_mangle)]
pub fn d() {}
trait W { unsafe fn e(); }
";
        let labels: Vec<String> = one(source).into_iter().map(|r| r.what).collect();
        assert_eq!(
            labels,
            [
                "unsafe { .. } block",
                "unsafe fn b",
                "unsafe impl",
                "unsafe trait U",
                "unsafe extern block",
                "unsafe attribute",
                "unsafe fn e",
            ]
        );
    }

    #[test]
    fn an_extern_fn_is_labelled_as_a_function_and_const_generic_braces_are_not_the_body() {
        let regions = one("pub unsafe extern \"C\" fn ffi(p: *const u8) -> u8 { *p }");
        assert_eq!(regions[0].what, "unsafe fn ffi");
        let source = "unsafe fn f(a: Wrap<{ N }>) -> u8 { BODY }";
        let regions = one(source);
        assert_eq!(regions.len(), 1);
        assert!(
            regions[0].fingerprint.contains("BODY"),
            "{}",
            regions[0].fingerprint
        );
    }

    // An array length is a const expression: `[u8; { N }]`. Its brace group
    // sits inside `[...]`, so `region_end` never sees it at the top level and
    // the region still runs to the function body. A future rewrite that
    // looks for "the first brace token" in the raw source instead of walking
    // token trees would stop at `{ N }` and leave the body outside the
    // fingerprint; this test pins the behaviour.
    #[test]
    fn an_array_length_const_block_is_not_the_body() {
        let source = "unsafe fn f<const N: usize>() -> [u8; { N + 1 }] { BODY }";
        let regions = one(source);
        assert_eq!(regions.len(), 1);
        assert!(
            regions[0].fingerprint.contains("BODY"),
            "the region stopped at the array length: {}",
            regions[0].fingerprint
        );
    }

    #[test]
    fn lines_point_at_the_keyword() {
        let regions = one("fn f() {}\n\nfn g(v: &[u8]) -> u8 {\n    unsafe { *v.as_ptr() }\n}\n");
        assert_eq!(regions.len(), 1);
        assert_eq!(regions[0].line, 4);
    }

    // The reason this module scans tokens instead of visiting a syntax tree.
    #[test]
    fn unsafe_inside_a_macro_invocation_and_a_macro_definition_is_found() {
        let invocation = "fn f(v: &[u8]) -> Vec<u8> { vec![unsafe { *v.get_unchecked(0) }] }";
        assert_eq!(one(invocation).len(), 1);
        let definition =
            "macro_rules! at { ($v:expr, $i:expr) => { unsafe { *$v.get_unchecked($i) } }; }";
        assert_eq!(one(definition).len(), 1);
    }

    #[test]
    fn a_nested_region_belongs_to_the_outer_one() {
        let regions = one("unsafe fn f(p: *const u8) -> u8 { unsafe { *p } }");
        assert_eq!(regions.len(), 1);
        assert_eq!(regions[0].what, "unsafe fn f");
    }

    #[test]
    fn a_shebang_line_does_not_defeat_the_scan() {
        let regions =
            one("#!/usr/bin/env run-cargo-script\nfn f(p: *const u8) -> u8 { unsafe { *p } }");
        assert_eq!(regions.len(), 1);
        assert_eq!(regions[0].line, 2);
    }

    #[test]
    fn an_untokenizable_file_that_mentions_unsafe_is_one_region() {
        let regions = one("fn f() { unsafe { \" }");
        assert_eq!(regions.len(), 1);
        assert_eq!(regions[0].line, 0);
        assert!(one("fn f() { \" }").is_empty());
    }

    #[test]
    fn a_new_block_is_a_violation_with_its_file_and_line() {
        let base = files(&[("src/lib.rs", "pub fn f(v: &[u8]) -> u8 { v[0] }\n")]);
        let cand = files(&[(
            "src/lib.rs",
            "pub fn f(v: &[u8]) -> u8 {\n    unsafe { *v.get_unchecked(0) }\n}\n",
        )]);
        let found = added(&base, &cand);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].file, "src/lib.rs");
        assert_eq!(found[0].line, 2);
    }

    // The case a "count the unsafe blocks" rule would miss: same number of
    // blocks, one more unchecked operation inside.
    #[test]
    fn changing_the_inside_of_an_existing_block_is_a_violation() {
        let base = files(&[("a.rs", "fn f(p: *const u8) -> u8 { unsafe { *p } }")]);
        let cand = files(&[("a.rs", "fn f(p: *const u8) -> u8 { unsafe { *p.add(1) } }")]);
        assert_eq!(added(&base, &cand).len(), 1);
    }

    #[test]
    fn reformatting_and_rewording_comments_is_not_a_violation() {
        let base = files(&[(
            "a.rs",
            "fn f(p: *const u8) -> u8 { unsafe { *p } }\n\
             /// Old words.\nunsafe fn g() { /* old */ }",
        )]);
        let cand = files(&[(
            "a.rs",
            "fn f(p: *const u8) -> u8 {\n    // SAFETY: caller passes a valid pointer.\n    \
             unsafe {\n        *p\n    }\n}\n/// New words.\nunsafe fn g() {\n    // new\n}",
        )]);
        assert_eq!(added(&base, &cand), Vec::new());
    }

    // A string literal inside an unsafe region is code, not prose: `asm!`'s
    // template and a `#[link_name]` decide what the program does. Dropping
    // literals from the fingerprint would let an agent change them freely.
    #[test]
    fn changing_a_string_inside_an_unsafe_region_is_a_violation() {
        let base = files(&[("a.rs", "fn f() { unsafe { asm!(\"nop\") } }")]);
        let cand = files(&[("a.rs", "fn f() { unsafe { asm!(\"ud2\") } }")]);
        assert_eq!(added(&base, &cand).len(), 1);
    }

    #[test]
    fn rewording_a_doc_comment_inside_an_unsafe_region_is_not_a_violation() {
        let base = files(&[("a.rs", "unsafe trait T {\n    /// Old.\n    fn f();\n}")]);
        let cand = files(&[(
            "a.rs",
            "unsafe trait T {\n    /// New wording.\n    fn f();\n}",
        )]);
        assert_eq!(added(&base, &cand), Vec::new());
    }

    #[test]
    fn removing_unsafe_is_always_allowed() {
        let base = files(&[(
            "a.rs",
            "fn f(v: &[u8]) -> u8 { unsafe { *v.get_unchecked(0) } }",
        )]);
        let cand = files(&[("a.rs", "fn f(v: &[u8]) -> u8 { v[0] }")]);
        assert!(added(&base, &cand).is_empty());
    }

    #[test]
    fn moving_an_untouched_region_between_files_is_not_a_violation() {
        let block = "pub fn f(p: *const u8) -> u8 { unsafe { *p } }";
        let base = files(&[("a.rs", block), ("b.rs", "")]);
        let cand = files(&[("a.rs", ""), ("b.rs", block)]);
        assert!(added(&base, &cand).is_empty());
    }

    #[test]
    fn a_second_copy_of_an_existing_region_is_a_violation() {
        let block = "fn f(p: *const u8) -> u8 { unsafe { *p } }";
        let base = files(&[("a.rs", block)]);
        let cand = files(&[
            ("a.rs", block),
            ("b.rs", "fn g(p: *const u8) -> u8 { unsafe { *p } }"),
        ]);
        let found = added(&base, &cand);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].file, "b.rs");
    }
}
