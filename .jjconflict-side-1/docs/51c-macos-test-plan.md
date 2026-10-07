# 51c — macOS adapter test plan

## 0. Scope, sources, and how to read this

This document is the test plan for `src/adapters/macos/`. It names every test,
says what that test asserts, and sorts the tests into the ones that run on this
Linux host and the ones that need a Mac. An implementer writing
`src/adapters/macos/` reads this beside `docs/42-native-adapter-build-map.md`
section 1.2, which is the census this plan tests against.

| Item | Value |
|---|---|
| Port | `zaccesskit`, a pure Zig port of the Rust `accesskit` crate |
| Upstream tree | `/tmp/scratch/accesskit` at `466e24e252103f4d82bd6fbab98141b551e46e0c` |
| Upstream crate | `accesskit_macos` 0.27.1, the tree at `adapters/macos/` |
| Citation prefix | `AK/macos/src/`, the prefix `docs/42` uses for that tree |
| Zig | 0.16.0 |
| Host running this plan | Linux. **No test in sections 1 to 4 needs macOS.** |

**Upstream state, checked before anything below was written.** `git log -1` at
that path returns `466e24e fix: Don't move focus when VoiceOver moves to an
element on iOS (#815)`, and `git status --porcelain` returns nothing. The tree is
clean and is the commit `docs/42` was written against, so its census and this
plan describe the same bytes.

**What this document owns.** The 43 selector-literal tests (§1), the role and
subrole mapping tests (§2), the attribute-access tests (§3), the notification
tests (§4), and the list of what remains unproven without a Mac (§5).

**What this document does not own.** The symbol census belongs to
`docs/42-native-adapter-build-map.md`. The module layout is fixed by
`docs/30-port-design.md`. The verification ladder — L1 compiles, L2 links, L3
runs — is defined in `docs/50-verification.md` and by `docs/42` section 3. Where
this document and those disagree, they win and this document is wrong.

**No gate stage was run to produce this plan.** Not `zig build`, not
`zig build test`, not `zig build cross-test`, not `zig-gate`, not `zig fmt`, not
`ziglint`, `zlint`, `zbc` or `zwanzig`. Every count below is a lexical scan over
the pinned upstream tree or over the current repository, and each one names the
scan that produced it.

### 0.1 How the counts in this plan were produced

Nothing here is transcribed from `docs/16-native-platform-apis.md`, whose macOS
literal count is wrong by 37 and is already recorded as `docs/50-risk-register.md`
row C2. Each number below was measured directly:

| Claim | How it was measured | Result |
|---|---|---:|
| 43 distinct `AX…` literals | `grep -ohE '"AX[A-Za-z]+"' AK/macos/src/node.rs \| sort -u \| wc -l` | **43** |
| 5 in `ns_role` | same scan restricted to lines 36–242 | **5** |
| 32 in `ns_sub_role` | same scan restricted to lines 244–296 | **32** |
| 3 attribute names | same scan restricted to lines 1090–1105 | **3** |
| 2 font keys | `grep -ohE '"AXFont[A-Za-z]+"'` | **2** |
| 1 action name | `grep -ohE '"AXScrollToVisible"'` | **1** |
| `ns_role` covers every role | set difference against the 182 `Role` variants in `src/schema/role.zig`, both directions | **0 and 0** |
| `ns_sub_role` arms | `grep -cE 'Role::[A-Za-z]+ =>'` over lines 244–296 | **44** |
| `ns_sub_role` arms that emit a literal | `grep -c 'ns_string!'` over the same range | **36** |
| selectors on `PlatformNode` | `grep -cE '#\[method(_id)?\('` over lines 411–1330 | **54** |
| selectors installed on the host view | `grep -ohE 'sel!\([a-zA-Z]+:?\)'` in `subclass.rs` | **4** |

**One count in `docs/42` is off by one and this plan does not inherit it.**
`docs/42` line 272 and line 344 report 70 distinct `NSAccessibility` identifiers.
A scan with a word boundary and at least one letter returns **69**: the 70th is
the bare protocol name `NSAccessibility`, which appears only in protocol-qualified
position such as `NSAccessibility::accessibilityParent` at `AK/macos/src/node.rs:421`
and never as an identifier of its own. Whether that name counts as an identifier
is a defensible question; 69 is what a plain scan returns. `docs/42` is not this
document's file and is not edited here.

### 0.2 The one structural fact that decides where these tests live

**`zig build test` does not reach `src/adapters/`.** `src/root.zig` has exactly
two project imports, `schema/root.zig` at line 33 and `consumer/root.zig` at line
46, and both are referenced by a `refAllDecls` test at lines 101 and 108. Nothing
in the repository imports `src/adapters/` or `src/capi/`. The test binary is
rooted at `src/root.zig` (`build.zig:58`, `:84`, `:113`), so tests in files the
root never imports are not compiled into it.

The arithmetic closes exactly and is not a guess:

| Reachable from `src/root.zig` | `^test ` declarations |
|---|---:|
| `src/schema/` | 317 |
| `src/consumer/` | 385 |
| `src/root.zig` | 4 |
| **Sum** | **706** |

706 is the reported gate count. The unreachable declarations are `src/capi/` at
141 and `src/adapters/` at 84. **A macOS literal test written into
`src/adapters/macos/` does not run in `zig build test` today.** That is not an
argument against putting the tests there — that is where the adapter belongs —
but it is an argument for making the reachability explicit rather than assuming
it. Two ways to close it, and the choice belongs to whoever owns `src/root.zig`
and `build.zig`:

1. Add a module for the macOS literals with its own `addTest` entry in
   `build.zig`, mirroring how `test/fuzz/` would need its own root. Nothing then
   depends on the package root reaching into a platform directory.
2. Add a `refAllDecls` reference from `src/root.zig` to a macOS literals module,
   exactly the mechanism lines 101 and 108 already use for `schema` and
   `consumer`.

Option 2 matches the existing pattern and keeps one `zig build test` command, at
the cost of a Linux-host package root naming a macOS module. Option 1 keeps the
package root platform-neutral and costs a second test root. **This plan does not
make that choice and does not write to either file.** It is recorded here because
a test plan that omits it produces 43 tests that never execute and reports them
as passing.

## 1. The 43 selector literals

### 1.1 Why this is the highest-value test surface on this adapter

`objc2-app-kit` exports no constants for any of the 43, which is why the Rust
source writes them as strings and why a Zig port writes 43 literals. A
misspelled subrole is a runtime wrong answer and no compile catches it: a Zig
string is a `[:0]const u8`, it is handed to `NSString` or compared against one,
and a typo produces an `NSString` the system has never heard of. The node answers
`accessibilitySubrole` with a string no assistive technology recognises, and the
tree is silently wrong in a way that looks like a platform bug.

Nothing else in the macOS adapter has that property. A wrong `NSAccessibility*`
constant name is a compile error because the constant is exported. A wrong
selector is close to a compile error because `sel!` names a symbol. A wrong
signature is caught by L1. **Only the 43 strings fail silently, and all 43 are
assertable on Linux with no framework, no SDK, and no Objective-C runtime.**

### 1.2 The three tests to write first

In this order.

**Test 1 — `test "the 43 AX selector literals are spelled exactly as upstream spells them"`.**
Holds the 43 strings in one table with the group each belongs to and the upstream
line it comes from, and asserts the table's length, its per-group counts of 5, 32,
3, 2 and 1, and every spelling against the literal upstream writes. One table,
one test, one file, no Mac. If this test is green the adapter cannot ship a
misspelled `AXLandmarkComplementary`, a `AXStrongStylegroup`, or an
`AXDOMIdentifier` written `AXDomIdentifier`.

**Test 2 — `test "ns_role maps all 182 Role variants and leaves none unmapped"`.**
Walks every variant of `schema.Role` and asserts `ns_role` answers for it,
asserting the variant count is 182. This is the exhaustiveness property, and it
is the one that catches a port which converts `ns_role`'s exhaustive `match` into
a `switch` with a silent `else`. It needs no Mac because it is arithmetic over an
enum and a table.

**Test 3 — `test "ns_sub_role answers for 44 roles and returns null for the other 138"`.**
Asserts the 44 mapped roles with their subrole values, and asserts the remaining
138 return null. This pins both halves of the contract: a role that maps to
something must map to the right something, and a role that maps to nothing must
return null rather than an empty string or a stale value.

These three cover every failure mode that reaches production silently. Everything
after them refines confidence in the same code.

### 1.3 The 43 literals, with provenance

Every line number below was read at the pinned commit.

**Group 1 — five role values, `ns_role`, `AK/macos/src/node.rs:36-242`.**

| Literal | Line | Zig role |
|---|---|---|
| `AXListMarker` | `:49` | `list_marker` |
| `AXDateField` | `:86` | `date_input`, `date_time_input`, `week_input`, `month_input` — one arm, four roles |
| `AXTimeField` | `:88` | `time_input` |
| `AXWebArea` | `:149` | `root_web_area` |
| `AXHeading` | `:224` | `doc_subtitle` |

**Group 2 — 32 subrole values, `ns_sub_role`, `AK/macos/src/node.rs:244-296`.**
Produced by 36 arms, because four spellings are each emitted by two roles.

| Literal | Lines | Zig roles that emit it |
|---|---|---|
| `AXApplicationAlert` | `:249` | `alert` |
| `AXWebApplication` | `:251` | `application` |
| `AXDocumentArticle` | `:252` | `article` |
| `AXLandmarkBanner` | `:253`, `:269` | `banner`, `header` |
| `AXCodeStyleGroup` | `:255` | `code` |
| `AXLandmarkComplementary` | `:256` | `complementary` |
| `AXDeleteStyleGroup` | `:257` | `content_deletion` |
| `AXInsertStyleGroup` | `:258` | `content_insertion` |
| `AXLandmarkContentInfo` | `:259`, `:265` | `content_info`, `footer` |
| `AXDefinition` | `:260` | `definition` |
| `AXDocument` | `:262`, `:267` | `document`, `graphics_document` |
| `AXEmphasisStyleGroup` | `:263` | `emphasis` |
| `AXApplicationGroup` | `:264`, `:268` | `feed`, `group` |
| `AXLandmarkForm` | `:266` | `form` |
| `AXApplicationLog` | `:270` | `log` |
| `AXLandmarkMain` | `:271` | `main` |
| `AXApplicationMarquee` | `:272` | `marquee` |
| `AXDocumentMath` | `:273` | `math` |
| `AXMeter` | `:274` | `meter` |
| `AXLandmarkNavigation` | `:275` | `navigation` |
| `AXDocumentNote` | `:276` | `note` |
| `AXLandmarkRegion` | `:278` | `region` |
| `AXLandmarkSearch` | `:279` | `search` |
| `AXSectionFooter` | `:281` | `section_footer` |
| `AXSectionHeader` | `:282` | `section_header` |
| `AXApplicationStatus` | `:283` | `status` |
| `AXStrongStyleGroup` | `:284` | `strong` |
| `AXTabPanel` | `:287` | `tab_panel` |
| `AXTerm` | `:288` | `term` |
| `AXTimeGroup` | `:289` | `time` |
| `AXApplicationTimer` | `:290` | `timer` |
| `AXUserInterfaceTooltip` | `:292` | `tooltip` |

**Group 3 — three attribute names, `accessibilityAttributeValue:`,
`AK/macos/src/node.rs:1090-1105`.**

| Literal | Line | Answered from |
|---|---|---|
| `AXBrailleLabel` | `:1093` | `Node.braille_label()` |
| `AXBrailleRoleDescription` | `:1095` | `Node.braille_role_description()` |
| `AXDOMIdentifier` | `:1097` | `Node.html_id()` |

`AXDOMIdentifier` is the one most likely to be "corrected" into `AXDomIdentifier`
or `AXDOMID` by a port that assumes consistent casing. It is not. Upstream spells
it with `DOM` capitalised and `Identifier` in full.

**Group 4 — two font-dictionary keys, `AK/macos/src/node.rs:892` and `:899`.**

| Literal | Line | Inserted when |
|---|---|---|
| `AXFontBold` | `:892` | `font_weight >= 700.0` |
| `AXFontItalic` | `:899` | `is_italic()` |

**Group 5 — one action name, `AK/macos/src/node.rs:34`.**

| Literal | Line | Use |
|---|---|---|
| `AXScrollToVisible` | `:34` | declared as `SCROLL_TO_VISIBLE_ACTION`; emitted by `accessibilityActionNames` at `:1212` and matched by `accessibilityPerformAction:` at `:1221` |

`AXScrollToVisible` is a **round trip**: the adapter publishes the name and then
compares an incoming name against it. A test that pins the emitted spelling but
not the comparison lets the two drift apart into a pair that never matches, which
is an action that is offered and silently does nothing. §4.4 tests the round
trip.

### 1.4 The 44th literal, which is not in the 43

`AK/macos/src/node.rs:125` reads:

```rust
Role::Heading => ns_string!("Heading"),
```

That is a literal with no `AX` prefix, which is why the `"AX[A-Za-z]+"` scan
returns 43 and not 44. Every other role the adapter emits carries the prefix.
The platform's own spelling for this role is `AXHeading`, and
`AK/macos/src/node.rs:224` writes `AXHeading` for `doc_subtitle` in the same file.

**The rule for this port is that upstream wins, so the port reproduces
`"Heading"`.** But a test plan that leaves this unpinned has created a trap: the
next reader sees an unprefixed role next to a prefixed one, "fixes" it, and ships
a change that no test notices. So:

**Test — `test "Role.heading emits the unprefixed string upstream emits"`.**
Asserts `ns_role(schema.Role.heading)` is exactly `"Heading"` and not
`"AXHeading"`, with a comment citing `AK/macos/src/node.rs:125`. If a later
decision is taken to correct this, the test is changed in the same commit that
changes the string, and the change is recorded as a deliberate divergence from
upstream rather than a silent repair.

This is the only place in the macOS adapter where the port must knowingly carry a
defect. It is worth exactly one test and one comment.

## 2. Role and subrole mapping

**The mapping is a table, and a table is testable on any host.** Nothing in this
section needs macOS, because neither `ns_role` nor `ns_sub_role` sends a message.
They are pure functions from a `Role` to a string or null, and `ns_role` reads
only `node.toggled()` at `AK/macos/src/node.rs:65`.

### 2.1 The role table is total, and that is a testable fact

`ns_role` has no `_` arm. Measured: it names **182** distinct roles, and
`src/schema/role.zig` declares **182** `Role` variants, `unknown = 0` at line 38
through `terminal = 181` at the end of the enum. Converting the Zig `snake_case`
spellings to the upstream `CamelCase` spellings and taking the set difference in
both directions returns **empty on both sides**: no Zig role is unmapped, and no
upstream arm names a role the port does not have.

This is stronger than "the switch compiles". A Zig `switch` over an enum with no
`else` is already a compile error on an unhandled variant, so L1 catches a missing
role. What L1 does **not** catch is the port introducing a catch-all to silence
such an error, or widening the mapping to a role that upstream leaves alone. The
exhaustiveness test catches the first; a value-equality test against the expected
182 catches the second.

**Test — `test "ns_role maps all 182 Role variants and leaves none unmapped"`.**
Two assertions. One walks `@typeInfo(schema.Role).@"enum"` and asserts
`ns_role` returns a non-empty role string for every variant, which is what a Zig
`switch` must do to compile at all and is stated here so the intent is not
inherited by accident. The other asserts the variant count is 182, matching the
upstream arm count, so adding a role to the port without adding it to the table
fails.

**Test — `test "the roles that share one AX literal share it deliberately"`.**
Six `ns_role` arms collapse onto fewer role strings, and each collapse is
upstream's intent rather than an accident:

| Output | Roles | Line |
|---|---|---|
| `AXUnknownRole` (`NSAccessibilityUnknownRole`) | `unknown`, `text_run`, `generic_container`, `pane`, `caret`, `feed`, `ime_candidate`, `keyboard`, `ruby_annotation`, `scroll_view`, `web_view`, `list_grid` | scattered |
| `NSAccessibilityGroupRole` | `list_item`, `paragraph`, `row_group`, `layout_table`, `layout_table_row`, `layout_table_cell`, and 95 more, for 98 roles in all | scattered |
| `NSAccessibilityCellRole` | `cell` and `grid_cell` on one arm, `row_header`, `column_header` — 3 arms, 4 roles | `:44`, `:76-77` |
| `NSAccessibilityStaticTextRole` | `label`, `list_box_option`, `title_bar` | `:45`, `:51`, `:202` |
| `NSAccessibilityTextFieldRole` | `text_input`, `search_input`, `email_input`, `number_input`, `password_input`, `phone_number_input`, `url_input` | `:58-64` |
| `NSAccessibilityRowRole` | `row`, `tree_item` | `:47`, `:50` |

The last row is the one a port is most likely to "clean up", because `tree_item`
becoming an outline row is the ARIA model rather than the macOS model. Upstream
maps it to a row in `ns_role` and to `NSAccessibilityOutlineRowSubrole` in
`ns_sub_role`, at `:291`. Both are asserted.

**Test — `test "Role.button maps to a checkbox when the node is toggled"`.**
The one place `ns_role` consults node state rather than the role alone
(`AK/macos/src/node.rs:65-71`). Asserts `button` with `toggled` present yields
`NSAccessibilityCheckBoxRole` and `button` without yields
`NSAccessibilityButtonRole`. A port that drops the conditional silently turns
every toggle into a push button.

**Test — `test "ns_role falls back to NSAccessibilityUnknownRole when the node is gone"`.**
`accessibilityRole` at `:501-506` resolves the node and falls back to
`NSAccessibilityUnknownRole` when resolution fails. Asserts the fallback string.
This is the `resolve` path, and it is the answer a client sees for a node that was
destroyed between the tree update and the message send.

### 2.2 The subrole table is partial, and the default is null

`ns_sub_role` has **44** arms naming **44** roles, and a `_ => None` default at
`AK/macos/src/node.rs:293`. Of those 44 arms, **36** emit one of the 32 literals
and **8** emit an `objc2-app-kit` constant:

| Role | Subrole | Source |
|---|---|---|
| `alert_dialog` | `NSAccessibilityDialogSubrole` | `:250` |
| `dialog` | `NSAccessibilityDialogSubrole` | `:261` |
| `button` with `toggled` present | `NSAccessibilityToggleSubrole` | `:254` |
| `password_input` | `NSAccessibilitySecureTextFieldSubrole` | `:277` |
| `search_input` | `NSAccessibilitySearchFieldSubrole` | `:280` |
| `switch_` | `NSAccessibilitySwitchSubrole` | `:281` |
| `tab` | `NSAccessibilityTabButtonSubrole` | `:286` |
| `tree_item` | `NSAccessibilityOutlineRowSubrole` | `:291` |

So the subrole mapping is 44 of 182 roles, and **138 roles must return null.**

**Test — `test "ns_sub_role answers for 44 roles and returns null for the other 138"`.**
Builds the 44-role set, walks all 182 variants, and asserts membership implies a
non-null subrole and absence implies null. Both directions in one walk, because
the two failure modes are different and both are silent: a role that maps to
nothing returning a string, and a role that maps to a string returning null.

**Test — `test "the four duplicated subrole spellings are emitted by both roles"`.**
`AXLandmarkBanner`, `AXLandmarkContentInfo`, `AXDocument` and
`AXApplicationGroup` are each emitted by two roles. Asserts both arms of each
pair. This exists because a distinctness check is the natural companion to Test 1
and it would otherwise reject the table: a port that deduplicates the 36 arms
into 32 has changed which roles answer, and the natural test for "no duplicate
strings" fights that change.

**Test — `test "the four subrole constants are the ones objc2-app-kit exports"`.**
Asserts the 8 constant arms spell the 7 distinct `NSAccessibility*Subrole`
constant names, and that `alert_dialog` and `dialog` share
`NSAccessibilityDialogSubrole`. These 8 arms need no Mac either — the constants
are compile-time names from `objc2-app-kit` and comparing their strings is a
compile-time comparison — but unlike the 43 they **are** caught by L1 if
misspelled. They are in this plan for completeness of the table, not because
they are silent.

### 2.3 What a node that maps to no subrole must do

It must return null from `ns_sub_role`, and `accessibilitySubrole` at
`AK/macos/src/node.rs:508-512` turns that into nil. It must **not** return an
empty string, and it must not fall back to the role string. A client that
receives an empty subrole has been told the node has a subrole whose name is "",
which is a different statement from "has no subrole".

**Test — `test "a role with no subrole answers nil rather than an empty string"`.**
Asserts the 138 unmapped roles return null from the accessor, and that
`accessibilitySubrole` is the only one of the 54 selectors that models "absent"
as nil rather than as a sentinel. See §3.1 for the full nil-capable list.

## 3. Attribute access

### 3.1 The 54 selectors and their types

`PlatformNode` implements **54** selectors. Return types, tallied from
`AK/macos/src/node.rs:411-1330`:

| Return shape | Count |
|---|---:|
| `Option<Id<NSString>>` | 8 |
| `Option<Id<NSArray<PlatformNode>>>` | 7 |
| `Option<Id<AnyObject>>` | 3 |
| `Option<Id<NSNumber>>` | 2 |
| `Option<Id<NSURL>>` | 1 |
| `Option<Id<NSObject>>` | 1 |
| `Option<Id<NSAttributedString>>` | 1 |
| `Option<Id<NSAccessibilitySubrole>>` | 1 |
| `bool` | 12 |
| `NSRange` | 5 |
| `NSInteger` | 3 |
| `NSRect` | 2 |
| `void` | 5 |
| `Id<NSAccessibilityRole>` | 1 |
| `Id<NSArray<NSString>>` | 1 |
| `NSAccessibilityOrientation` | 1 |

**24 of the 54 are nil-capable.** Those 24 are the ones whose `nil` case is a
distinct behaviour, and the other 30 all have a total answer whether or not the
node resolves.

**Test — `test "the node implements 54 selectors, 24 of which can answer nil"`.**
Asserts both counts from a table of `{ selector, may_be_nil }`. The value is the
count agreement with `docs/42`: a port that adds a selector and forgets to add
its row fails, and a port that drops one fails.

**Test — `test "the four selectors installed on the host view are spelled as upstream spells them"`.**
`superclass`, `accessibilityChildren`, `accessibilityFocusedUIElement`,
`accessibilityHitTest:`, at `AK/macos/src/subclass.rs:179`, `:183`, `:187`,
`:191`. These are passed to `builder.add_method`, so a misspelling is a selector
the runtime never installs and the view silently keeps its original behaviour.
Like the 43, no compile catches it: `sel!` accepts any name.

### 3.2 The nil case, selector by selector

The 24 nil-capable selectors, each with what nil means:

| Selector | Line | nil means |
|---|---|---|
| `accessibilityParent` | `:412` | no filtered parent **and** no host view parent |
| `accessibilityWindow` | `:427` | host view is gone |
| `accessibilityTopLevelUIElement` | `:438` | host view is gone |
| `accessibilityChildren` | `:449` | node unresolved, or not a container |
| `accessibilityChildrenInNavigationOrder` | `:454` | same as `accessibilityChildren` |
| `accessibilitySelectedChildren` | `:460` | not a container with selectable children |
| `accessibilitySubrole` | `:508` | **the 138 unmapped roles of §2.2** |
| `accessibilityRoleDescription` | `:514` | no `role_description` and superclass returned nil |
| `accessibilityIdentifier` | `:526` | no `author_id` |
| `accessibilityTitle` | `:534` | no `title` |
| `accessibilityHelp` | `:543` | no `description` |
| `accessibilityPlaceholderValue` | `:552` | no `placeholder` |
| `accessibilityValue` | `:561` | no value of any of the three shapes |
| `accessibilityMinValue` | `:607` | no `min_numeric_value` |
| `accessibilityMaxValue` | `:615` | no `max_numeric_value` |
| `accessibilityURL` | `:623` | unsupported, absent, or `NSURL` rejected the string |
| `accessibilitySelectedText` | `:767` | no text ranges, or no selection |
| `accessibilityStringForRange:` | `:840` | range does not resolve |
| `accessibilityAttributedStringForRange:` | `:854` | range does not resolve |
| `accessibilityAttributeValue:` | `:1090` | unknown attribute **or** known attribute with no value |
| `accessibilityRows` | `:1106` | not a container with selectable children |
| `accessibilitySelectedRows` | `:1122` | not a container with selectable children |
| `accessibilityLinkedUIElements` | `:1161` | no linked elements |
| `accessibilityTabs` | `:1178` | not a tab list |

**Test — `test "accessibilityAttributeValue answers nil for a known attribute whose node has no value"`.**
This is the subtle one. `accessibilityAttributeValue:` at
`AK/macos/src/node.rs:1090-1104` compares the attribute against the three
literals **and** checks the corresponding node method: `attr == AXBrailleLabel &&
node.has_braille_label()`. A node with no braille label answers nil for
`AXBrailleLabel` rather than an empty `NSString`. Asserts all three attributes
against a node that has the property and one that does not. A port that drops the
`has_*` conjunct answers an empty string and a client reads that as a blank label.

**Test — `test "the four non-nil selectors answer their sentinel when the node is gone"`.**
`accessibilityFrame` returns `NSRect::ZERO` (`:478`), `accessibilityOrientation`
returns `NSAccessibilityOrientationUnknown` (`:635`),
`accessibilityNumberOfCharacters` returns `0` (`:756`), and
`accessibilitySelectedTextRange` returns `NSRange{0, 0}` (`:782`). Asserting the
sentinels is what distinguishes "unresolved" from "resolved to nothing", and a
port that returns nil from these four is a compile-shaped change that a client
sees as a crash rather than an empty element.

**Test — `test "accessibilityRoleDescription falls back to the superclass"`.**
`:514-524` sends `accessibilityRoleDescription` to `super` when the node carries
no `role_description`. Asserts the node value wins when present and the superclass
answer is used otherwise. The fallback is a message send to the host view and
cannot be tested without a Mac, but **the precedence is testable on any host** by
injecting the superclass answer.

### 3.3 The value shape test

`accessibilityValue` at `:561-579` returns `Option<Id<NSObject>>` and the concrete
class depends on the node's value: `NSNumber` for bool, `NSNumber` for number,
`NSString` for string.

**Test — `test "accessibilityValue returns NSNumber for bool and number, NSString for string"`.**
Asserts the class of the returned object per value shape. The three shapes are
indistinguishable to a client that only asks "is this a string", and getting bool
and number both right as `NSNumber` matters because
`setAccessibilityValue:` at `:581-605` downcasts in the other direction with two
`downcast_ref` calls — the helper is defined at `:386` — whose order decides the
result for an `NSNumber`.

**Test — `test "setAccessibilityValue downcasts NSString before NSNumber"`.**
Asserts a string sets `ActionData::Value` and a number sets
`ActionData::NumericValue`. The two downcasts at `:582` and `:593` are ordered,
and a port that reorders them sends the wrong action payload.

### 3.4 `isAccessibilitySelectorAllowed:`

`:1235-1330` is a second, independent answer to "does this node support that",
dispatched on 24 selectors across six groups. It is a switch over a `Sel` with no
default arm, so an unlisted selector falls through.

**Test — `test "isAccessibilitySelectorAllowed groups its 24 selectors into six answers"`.**
The groups, from `:1238-1272`: focus (`setAccessibilityFocused:` →
`is_focusable`), click (`accessibilityPerformPress` → `is_clickable`),
increment, decrement, the 13 text-range selectors, `setAccessibilityValue:`
→ text ranges and not read-only, or `supports_action(SetValue)`,
`isAccessibilitySelected` → `is_item_like`, and `accessibilityRows` /
`accessibilitySelectedRows` → container with selectable children.

The 13 text-range selectors are one arm and must stay one arm:
`accessibilityNumberOfCharacters`, `accessibilitySelectedText`,
`accessibilitySelectedTextRange`, `accessibilityInsertionPointLineNumber`,
`accessibilityRangeForLine:`, `accessibilityRangeForPosition:`,
`accessibilityStringForRange:`, `accessibilityAttributedStringForRange:`,
`accessibilityFrameForRange:`, `accessibilityLineForIndex:`,
`accessibilityRangeForIndex:`, `accessibilityStyleRangeForIndex:`,
`setAccessibilitySelectedTextRange:`. A port that splits them into 13 arms
behaves identically and is a large diff for nothing; a port that drops one
behaves differently and is the defect this test catches.

**Test — `test "isAccessibilitySelectorAllowed answers false for an unlisted selector"`.**
Asserts the fall-through. The predicates are the port's own
`src/consumer/node_ref/predicates.zig` — `isFocusable` at `:82`, `isClickable`
at `:149`, `supportsIncrement` at `:250`, `supportsDecrement` at `:255`,
`supportsAction` at `:239`, `isReadOnly` at `:277` — so a synthetic tree in a
test answers all of them on Linux.

## 4. Notifications

### 4.1 The seven notification names

The adapter posts through two functions and names seven distinct notifications.
Measured over `AK/macos/src/event.rs`, `context.rs` and `node.rs`:

| Notification | Line | Posted for |
|---|---|---|
| `NSAccessibilityFocusedUIElementChangedNotification` | `event.rs:136` | focus moved to a node |
| `NSAccessibilityValueChangedNotification` | `event.rs:189`, `:281`, `:287` | value changed, or text changed |
| `NSAccessibilityTitleChangedNotification` | `event.rs:267` | title changed |
| `NSAccessibilitySelectedTextChangedNotification` | `event.rs:297` | text selection changed |
| `NSAccessibilitySelectedRowsChangedNotification` | `event.rs:211` | selected rows changed |
| `NSAccessibilityUIElementDestroyedNotification` | `event.rs:60`, `context.rs:96` | node destroyed, or context dropped |
| `NSAccessibilityAnnouncementRequestedNotification` | `event.rs:99` | live-region announcement |

The first six go through `NSAccessibilityPostNotification` at `event.rs:53` and
`:58`. The seventh goes through `NSAccessibilityPostNotificationWithUserInfo` at
`event.rs:97`.

**Test — `test "the adapter names exactly seven notifications and picks the right one per change"`.**
A table of `{ change, notification }` over a synthetic tree and an
`EventGenerator`. **This needs no Mac.** The generator decides which notification
to name; only the final `NSAccessibilityPostNotification` call needs the
framework. Testing the decision function and the post call separately is what
makes this runnable here.

**Test — `test "a tree update posts nothing for an unchanged node"`.**
The negative case. Asserts a no-op update produces zero events, which is the
property that keeps a real application from being flooded with spurious VoiceOver
announcements.

### 4.2 The `userInfo` dictionary

The announcement path is the only one that publishes a `userInfo`. From
`AK/macos/src/event.rs:76-101`:

| Key | Line | Value |
|---|---|---|
| `NSAccessibilityAnnouncementKey` | `:85` | the announcement text as an `NSString` |
| `NSAccessibilityPriorityKey` | `:92` | `NSNumber` of `NSAccessibilityPriorityLevel` |

The priority is chosen from the node's `live` at `event.rs:35-43`:
`live == Assertive` gives `NSAccessibilityPriorityHigh`, anything else gives
`NSAccessibilityPriorityMedium`. The port's enum is `schema.Live` at
`src/schema/node_enums.zig:121` with three tags, `off = 0`, `polite = 1`,
`assertive = 2`.

**Test — `test "an assertive live region announces at high priority and a polite one at medium"`.**
Asserts both arms against `schema.Live`. **No Mac needed** — the mapping from a
`Live` tag to a priority level is a two-arm function. What needs a Mac is
delivering the dictionary.

**Test — `test "the announcement is posted to the window, not to the node"`.**
`event.rs:73-79` resolves `view.window()` and posts there, and returns without
posting when either is nil. Asserts the target selection and both nil
early-returns. The *choice* of window is testable with a stubbed view; the
*post* is not.

### 4.3 The argument the system passes back

`accessibilityPerformAction:` at `AK/macos/src/node.rs:1219-1232` receives an
`NSString` from the system and compares it to `AXScrollToVisible`. That incoming
string is **the only value the system ever passes the adapter through this
selector**, and the adapter has exactly one action name to receive.

**Test — `test "accessibilityPerformAction dispatches only the action name the adapter published"`.**
Asserts that `AXScrollToVisible` produces `Action::ScrollIntoView` and that any
other string produces nothing. The comparison is
`action == ns_string!(SCROLL_TO_VISIBLE_ACTION)` at `:1221`.

### 4.4 The action-name round trip

`accessibilityActionNames` at `:1207-1217` publishes `AXScrollToVisible` when the
node supports `Action::ScrollIntoView`, and returns an `NSArray` that is **empty,
not nil, when it does not** — the array is constructed outside the `resolve`
closure at `:1215`, so the nil path still yields an empty array. That is the one
selector among the 54 that returns a non-optional empty value, and it is the one
place the port can get "absent" wrong without noticing.

**Test — `test "accessibilityActionNames is empty rather than nil when no action is supported"`.**
Asserts both arms. A port returning nil here crashes a client that indexes the
array, and one returning a one-element array for an unsupported node offers an
action that does nothing.

**Test — `test "the name published by accessibilityActionNames is the name performAction matches"`.**
The round trip from §1.3. Takes the array `accessibilityActionNames` returns,
feeds each element to `accessibilityPerformAction:`, and asserts each produces its
action. Without this test the two literals can drift and the action is offered
and silently does nothing — the single most likely silent failure in the whole
adapter, because both halves are individually correct.

### 4.5 The destruction path

`QueuedEvent::NodeDestroyed` at `event.rs:55-64` removes the platform node and
posts `NSAccessibilityUIElementDestroyedNotification`. `Context::drop` at
`context.rs:91-102` posts the same notification for every remaining node.
`remove_subtree` at `event.rs:161-174` enqueues one destruction per node in the
subtree, depth-first.

**Test — `test "dropping a context posts one destroyed notification per live node"`.**
**No Mac needed** if the post function is injected, which it must be for any of
this section to be testable at all. Asserts the count and the notification name.

**Test — `test "removing a subtree enqueues one destruction per node in it"`.**
Asserts the count for a three-node subtree and the order. Depth-first
(`VecDeque` with `push_back` at `event.rs:163` and `:167`, drained by `pop_front`
at `:165`) yields a
pre-order walk, and the order is what a client uses to tear down.

## 5. What needs macOS, and what it proves

Everything in sections 1 to 4 runs on this Linux host. This section is the
remainder, and each row names what the test proves that its absence leaves
unproven.

**The point of §5 being this short is the point of this document.** The 43 literal
tests, the 182-role exhaustiveness test, the 44-role subrole test, the 54-selector
type table, the seven-notification decision table and the priority mapping are all
assertable on a machine with no Mac, no Xcode, no `libobjc`, and no AppKit. **That
is why this is the most testable adapter in the port.** The AT-SPI adapter's
surface is D-Bus wire types, testable only with a peer; the Windows adapter's is
COM vtable shapes, testable only against a live UIA client; the Android adapter's
is JNI signatures, unreachable until an NDK exists. The macOS adapter's substance
is 43 strings and two tables, and strings and tables are what a unit test is.

**This matters because the macOS adapter is also the one adapter that cannot be
compiled or linked here.** `zig build-exe -target aarch64-macos` fails at `-lobjc`
with `unable to find dynamic system library 'objc'`, recorded as `docs/16:1780`
and as row H5 of `docs/50-verification.md`. `translate-c` cannot parse an
Objective-C header, recorded at `docs/16:1784` and analysed in `docs/42` section
2.5. So the adapter is simultaneously the adapter whose **logic** is most
testable and whose **build** is least verifiable here. Sections 1 to 4 are how
the port gets real evidence anyway.

### 5.1 Needs a Mac to compile or link — L1 and L2

| Test | Needs | Proves |
|---|---|---|
| `zig build-obj -target aarch64-macos` | the macOS target | the adapter's Zig source type-checks for the target ABI. **Proves nothing about linking.** `docs/42` §3.1 records that an object file is not linked, so this passes with no Foundation framework in the picture. |
| `zig build-exe -target aarch64-macos` with the framework flags | a Mac with the SDK | the declarations link against real AppKit and Foundation. This is the step that fails on this host. |

### 5.2 Needs a Mac to run — L3

| Test | Needs | Proves |
|---|---|---|
| `accessibilityRole` returns a string the system recognises | a running application with an assistive technology client | that `AXListMarker`, `AXDateField` and the rest are the **strings macOS accepts**, not merely the strings upstream writes. §1 proves the port matches upstream; only this proves upstream is right. |
| `accessibilitySubrole` is honoured for `AXLandmarkMain` | VoiceOver or AX Inspector | that a landmark subrole is interpreted as a landmark. A misspelling fails silently, which is §1's whole subject. |
| `accessibilityAttributeValue:` answers `AXDOMIdentifier` | a client that reads it | that the WebKit-facing attribute name is right at runtime. |
| `NSAccessibilityPostNotification` reaches a client | a live AX client | that the framework function is correctly declared and linked. **This is the first thing that proves L2.** |
| `NSAccessibilityAnnouncementRequestedNotification` with `userInfo` | a live AX client | that the two `userInfo` keys and the priority `NSNumber` are the ones the system reads. A wrong key posts a silent announcement. |
| `accessibilityHitTest:` on the host view subclass | a click | that the four installed selectors took effect and `object_setClass` succeeded. |
| `class_addMethod` for `accessibilityFocusedUIElement` on an `NSWindow` subclass | an SDL- or winit-style host | the `add_focus_forwarder_to_window_class` path at `AK/macos/src/patch.rs:39`, which calls `class_addMethod` at `:71`. |
| The font dictionary reaches VoiceOver | a text node with bold and italic | that `AXFontBold` and `AXFontItalic` are the keys the system reads, inside `NSAccessibilityFontTextAttribute`. |
| `AXScrollToVisible` scrolls | a scrollable node | the full round trip of §4.4 against a real scroll view. |

### 5.3 The evidence ladder, stated plainly

| Level | Claim | This plan's contribution |
|---|---|---|
| L1 compiles | source type-checks for the target | the 54-selector type table and the 182-role exhaustiveness test are the parts of L1 that can be anticipated here |
| L2 links | the object links against real system libraries | **nothing in this plan.** Needs §5.1. |
| L3 runs | the adapter works against a live assistive technology | **nothing in this plan.** Needs §5.2. |

**A green run of sections 1 to 4 is evidence about the port's tables and nothing
else.** It is not evidence that the adapter builds, and it is not evidence that
the adapter works. Recording it as more than that is the failure mode
`docs/50-verification.md` H5 exists to prevent.

## 6. Test inventory

Grouped by whether it needs macOS, as the acceptance criterion requires.

### 6.1 Needs no macOS — 31 tests

These need no Mac. Whether they *run* under `zig build test` today is the separate
question §0.2 answers: they do not, because `src/root.zig` does not import
`src/adapters/`. Nothing in this list depends on a Mac; the reachability gap is
independent of it.

**The 43 literals (5 tests)**

| # | Test | Asserts |
|---|---|---|
| 1 | `the 43 AX selector literals are spelled exactly as upstream spells them` | the table holds 43, split 5/32/3/2/1, and every spelling equals upstream's |
| 2 | `Role.heading emits the unprefixed string upstream emits` | `heading` yields `"Heading"`, not `"AXHeading"` (`AK/macos/src/node.rs:125`) |
| 3 | `no two literals in a group are equal` | within-group distinctness for all five groups |
| 4 | `every literal carries the upstream line it comes from` | provenance is not lost |
| 5 | `the four duplicated subrole spellings are emitted by both roles` | `AXLandmarkBanner`, `AXLandmarkContentInfo`, `AXDocument`, `AXApplicationGroup` each come from two roles |

**The role and subrole tables (7 tests)**

| # | Test | Asserts |
|---|---|---|
| 6 | `ns_role maps all 182 Role variants and leaves none unmapped` | every variant answers; the count is 182 |
| 7 | `the roles that share one AX literal share it deliberately` | the six collapse groups of §2.1 |
| 8 | `Role.button maps to a checkbox when the node is toggled` | the conditional at `:65-71` |
| 9 | `ns_role falls back to NSAccessibilityUnknownRole when the node is gone` | the `resolve` fallback |
| 10 | `ns_sub_role answers for 44 roles and returns null for the other 138` | both directions over all 182 |
| 11 | `the four subrole constants are the ones objc2-app-kit exports` | the 8 constant arms and the shared `NSAccessibilityDialogSubrole` |
| 12 | `a role with no subrole answers nil rather than an empty string` | absent is nil, not `""` |

**Attribute access (10 tests)**

| # | Test | Asserts |
|---|---|---|
| 13 | `the node implements 54 selectors, 24 of which can answer nil` | both counts against `docs/42` |
| 14 | `the four selectors installed on the host view are spelled as upstream spells them` | `superclass`, `accessibilityChildren`, `accessibilityFocusedUIElement`, `accessibilityHitTest:` |
| 15 | `accessibilityAttributeValue answers nil for a known attribute whose node has no value` | the `has_*` conjuncts on all three attributes |
| 16 | `the four non-nil selectors answer their sentinel when the node is gone` | `NSRect::ZERO`, orientation unknown, `0`, `NSRange{0,0}` |
| 17 | `accessibilityRoleDescription falls back to the superclass` | node value wins, superclass otherwise |
| 18 | `accessibilityValue returns NSNumber for bool and number, NSString for string` | the concrete class per value shape |
| 19 | `setAccessibilityValue downcasts NSString before NSNumber` | `ActionData::Value` vs `ActionData::NumericValue` |
| 20 | `isAccessibilitySelectorAllowed groups its 24 selectors into six answers` | the six groups and the 13-selector text arm |
| 21 | `isAccessibilitySelectorAllowed answers false for an unlisted selector` | the fall-through |
| 22 | `accessibilityURL answers nil when the platform rejects the string` | the `URLWithString` nil path at `:628` |

**Notifications (7 tests)**

| # | Test | Asserts |
|---|---|---|
| 23 | `the adapter names exactly seven notifications and picks the right one per change` | the change-to-notification table |
| 24 | `a tree update posts nothing for an unchanged node` | the negative case |
| 25 | `an assertive live region announces at high priority and a polite one at medium` | both `Live` arms |
| 26 | `the announcement is posted to the window, not to the node` | target selection and both nil early-returns |
| 27 | `accessibilityPerformAction dispatches only the action name the adapter published` | `AXScrollToVisible` in, `ScrollIntoView` out |
| 28 | `accessibilityActionNames is empty rather than nil when no action is supported` | both arms of `:1207-1217` |
| 29 | `the name published by accessibilityActionNames is the name performAction matches` | the round trip |

**Destruction (2 tests)**

| # | Test | Asserts |
|---|---|---|
| 30 | `dropping a context posts one destroyed notification per live node` | count and name |
| 31 | `removing a subtree enqueues one destruction per node in it` | count and pre-order |

**31 tests, none of which needs a Mac**, against 11 that do. The ratio is the
argument of this document.

### 6.2 Needs macOS — 11 tests

The two L1 and L2 compile-and-link probes of §5.1 and the nine L3 runtime
assertions of §5.2. Each is named in §5 with what it proves.

### 6.3 The three written first

Repeated from §1.2 because it is the acceptance criterion and it is the answer to
"where do I start":

1. **`the 43 AX selector literals are spelled exactly as upstream spells them`** —
   one table, one test, no Mac, catches every silent typo the adapter can ship.
2. **`ns_role maps all 182 Role variants and leaves none unmapped`** — the
   exhaustiveness property, catches a catch-all `else` introduced to silence a
   compile error.
3. **`ns_sub_role answers for 44 roles and returns null for the other 138`** —
   pins both halves of a partial table, in one walk.

## 7. Two things this plan could not establish

**Unverified: whether the 43 spellings are the strings macOS accepts.** §1 proves
the port matches upstream at `466e24e`. Nothing here proves upstream is correct.
`AXDOMIdentifier` and `AXUserInterfaceTooltip` are the two where an upstream typo
would survive every test in §6.1 and still produce a node the platform ignores.
Resolving this needs §5.2 and a Mac. This is recorded rather than assumed.

**Unverified: the exact shape of `objc2-app-kit`'s constants for the 8 subrole
arms of §2.2.** The names are read from the upstream source at
`AK/macos/src/node.rs:250-291` and the port spells them from
`docs/42` §1.2.5. Whether `objc2-app-kit` exports each of the 7
`NSAccessibility*Subrole` names under exactly that spelling was not checked
against the crate, because the crate is not vendored in this repository and the
build map records the dependency as `objc2-app-kit` 0.5.1 without its contents.
If one is exported under a different spelling, L1 catches it at build time and
§6.1 test 11 does not need to change. What would **not** be caught is a constant
that exists but carries a different string, and that needs a Mac.
