# 15 — Tree semantics: roles, properties, relations, and the node model

Consumed by `docs/30-port-design.md`, which turns these findings into Zig type
design, and by `docs/40-plan.md`, which turns that design into milestones.

This document is research. Sections 1 through 6 are findings. Every factual
claim carries a source: `path:line` for code, or the command and its output for
anything else. Section 7 is a proposal and says so. Section 8 proposes a
fixture format and says so. Anything not directly observed is marked
`[INFERENCE]`.

## Sources and versions

| What | Where | Version |
|---|---|---|
| AccessKit core | `/tmp/scratch/accesskit`, commit `466e24e252103f4d82bd6fbab98141b551e46e0c` | crate `accesskit` 0.25.1 |
| AccessKit C bindings | `/tmp/scratch/accesskit-c`, commit `8b6ed37c20ed4c59390e253407983333053662ba` | crate `accesskit-c` 0.23.1 |
| WAI-ARIA 1.2 | `https://www.w3.org/TR/2023/REC-wai-aria-1.2-20230606/` | REC, 2023-06-06 |
| WAI-ARIA 1.3 | `https://www.w3.org/TR/wai-aria-1.3/` | working draft |
| WAI-ARIA Graphics Module 1.0 | `https://www.w3.org/TR/graphics-aria-1.0/` | REC |
| DPUB-ARIA 1.0 | `https://www.w3.org/TR/dpub-aria-1.0/` | REC |
| DPUB-AAM 1.0 | `https://www.w3.org/TR/dpub-aam-1.0/` | REC |

Line counts of the primary sources, from `wc -l`:

```
3698 /tmp/scratch/accesskit/accesskit/src/lib.rs
1367 /tmp/scratch/accesskit/adapters/macos/src/node.rs
1539 /tmp/scratch/accesskit/adapters/windows/src/node.rs
2065 /tmp/scratch/accesskit/adapters/atspi-common/src/node.rs
```

The ARIA specifications were reachable. The role names and one-line meanings
in section 1 come from the "Definition of Roles" sections of those documents,
not from memory.

### A version correction the port must not repeat

`accesskit-c` is version 0.23.1, but that is the version of the **bindings
crate**, not of the core crate. Its manifest pins the core:

```
$ grep -n 'accesskit' /tmp/scratch/accesskit-c/Cargo.toml
20:accesskit = "0.25.1"
```

So the C header at `include/accesskit.h` already contains
`accesskit_node_set_html_id` (`include/accesskit.h:1617`) and
`accesskit_node_set_tree_id` (`include/accesskit.h:1464`). `local://zaccesskit-deps.md`
lists the bindings crate as 0.23.1 and the core as 0.25.1. Read that as two
independent crate versions, not as a two-release gap: the bindings track the
core. The port should target the core version for the data model.

---

## 1. The role model

`Role` is declared at `accesskit/src/lib.rs:62` with `#[repr(u8)]`
(`lib.rs:61`). The enum has **182 variants**, discriminants 0 through 181.

The doc comment at `lib.rs:37`-`lib.rs:46` states the ordering rule:

> The majority of these roles come from the ARIA specification. [...] Like the
> AccessKit schema as a whole, this list is largely taken from Chromium.
> However, unlike Chromium's alphabetized list, this list is ordered roughly by
> expected usage frequency (with the notable exception of `Role::Unknown`).
> This is more efficient in serialization formats where integers use a
> variable-length encoding.

Discriminant order is therefore **wire-visible and must not change**. The C
bindings confirm it: `grep -c 'ACCESSKIT_ROLE_' include/accesskit.h` returns
`182`, and the last two entries are `ACCESSKIT_ROLE_LIST_GRID`
(`include/accesskit.h:476`) and `ACCESSKIT_ROLE_TERMINAL`
(`include/accesskit.h:482`), which match `lib.rs:265` and `lib.rs:270`.

In the table below, `lib.rs:N` means
`/tmp/scratch/accesskit/accesskit/src/lib.rs:N`.

### 1.1 Every role

| Discriminant | Rust name | path:line | Specification | ARIA / AAM equivalent | Meaning |
|---|---|---|---|---|---|
| 0 | `Unknown` | `lib.rs:64` | none | **none** | Type is not known. This is the default value of Role. |
| 1 | `TextRun` | `lib.rs:65` | none | **none** | A run of text with per-character positions and widths. Only Role::TextRun nodes carry character_lengths, word_starts, character_positions and character_widths. |
| 2 | `Cell` | `lib.rs:66` | ARIA 1.2 | `cell` | A cell in a tabular container. See related gridcell. |
| 3 | `Label` | `lib.rs:67` | none | **none** | A short text that names or describes another object. Its text content is carried by the value property, not by label. |
| 4 | `Image` | `lib.rs:68` | ARIA 1.3 | `image` | A container for a collection of elements that form an image. See synonym img. |
| 5 | `Link` | `lib.rs:69` | ARIA 1.2 | `link` | An interactive reference to an internal or external resource that, when activated, causes the user agent to navigate to that resource. See related button. |
| 6 | `Row` | `lib.rs:70` | ARIA 1.2 | `row` | A row of cells in a tabular container. |
| 7 | `ListItem` | `lib.rs:71` | ARIA 1.2 | `listitem` | A single item in a list or directory. |
| 8 | `ListMarker` | `lib.rs:74` | none | **none** | The bullet, number or other marker of a list item. It has no children of its own. |
| 9 | `TreeItem` | `lib.rs:76` | ARIA 1.2 | `treeitem` | An option item of a tree. This is an element within a tree that may be expanded or collapsed if it contains a sub-level group of tree item elements. |
| 10 | `ListBoxOption` | `lib.rs:77` | ARIA 1.2 | `option` | A selectable item in a listbox. |
| 11 | `MenuItem` | `lib.rs:78` | ARIA 1.2 | `menuitem` | An option in a set of choices contained by a menu or menubar. |
| 12 | `MenuListOption` | `lib.rs:79` | none | **none** | An option inside a native select element that acts as a menu. Chromium-only role. |
| 13 | `Paragraph` | `lib.rs:80` | ARIA 1.2 | `paragraph` | A paragraph of content. |
| 14 | `GenericContainer` | `lib.rs:85` | ARIA 1.2 | `none / presentation` | The source doc comment states: equivalent to the ARIA none or presentation role, or to an HTML div with no role. |
| 15 | `CheckBox` | `lib.rs:87` | ARIA 1.2 | `checkbox` | A checkable input that has three possible values: true, false, or mixed. |
| 16 | `RadioButton` | `lib.rs:88` | ARIA 1.2 | `radio` | A checkable input in a group of elements with the same role, only one of which can be checked at a time. |
| 17 | `TextInput` | `lib.rs:89` | ARIA 1.2 | `textbox` | A type of input that allows free-form text as its value. |
| 18 | `Button` | `lib.rs:90` | ARIA 1.2 | `button` | An input that allows for user-triggered actions when clicked or pressed. See related link. |
| 19 | `DefaultButton` | `lib.rs:91` | ARIA 1.2 | `button` | Same ARIA role as button. Chromium adds a default-button distinction that ARIA has no state for. |
| 20 | `Pane` | `lib.rs:92` | ARIA 1.2 | `generic` | A nameless container element that has no semantic meaning on its own. |
| 21 | `RowHeader` | `lib.rs:93` | ARIA 1.2 | `rowheader` | A cell containing header information for a row. |
| 22 | `ColumnHeader` | `lib.rs:94` | ARIA 1.2 | `columnheader` | A cell containing header information for a column. |
| 23 | `RowGroup` | `lib.rs:95` | ARIA 1.2 | `rowgroup` | A structure containing one or more row elements in a tabular container. |
| 24 | `List` | `lib.rs:96` | ARIA 1.2 | `list` | A section containing listitem elements. See related listbox. |
| 25 | `Table` | `lib.rs:97` | ARIA 1.2 | `table` | A section containing data arranged in rows and columns. See related grid. |
| 26 | `LayoutTableCell` | `lib.rs:98` | none | **none** | A cell that exists only for layout. Assistive technology should ignore it. |
| 27 | `LayoutTableRow` | `lib.rs:99` | none | **none** | A row that exists only for layout. Assistive technology should ignore it. |
| 28 | `LayoutTable` | `lib.rs:100` | none | **none** | A table that exists only for layout. Assistive technology should ignore it. |
| 29 | `Switch` | `lib.rs:101` | ARIA 1.2 | `switch` | A type of checkbox that represents on/off values, as opposed to checked/unchecked values. See related checkbox. |
| 30 | `Menu` | `lib.rs:102` | ARIA 1.2 | `menu` | A type of widget that offers a list of choices to the user. |
| 31 | `MultilineTextInput` | `lib.rs:104` | ARIA 1.2 | `textbox` | An ARIA textbox whose aria-multiline is true. |
| 32 | `SearchInput` | `lib.rs:105` | ARIA 1.2 | `searchbox` | A type of textbox intended for specifying search criteria. See related textbox and search. |
| 33 | `DateInput` | `lib.rs:106` | none | **none** | A date entry field. Chromium-only role. |
| 34 | `DateTimeInput` | `lib.rs:107` | none | **none** | A combined date and time entry field. Chromium-only role. |
| 35 | `WeekInput` | `lib.rs:108` | none | **none** | A week entry field. Chromium-only role. |
| 36 | `MonthInput` | `lib.rs:109` | none | **none** | A month entry field. Chromium-only role. |
| 37 | `TimeInput` | `lib.rs:110` | none | **none** | A time entry field. Chromium-only role. |
| 38 | `EmailInput` | `lib.rs:111` | none | **none** | An email entry field. Chromium-only role. |
| 39 | `NumberInput` | `lib.rs:112` | none | **none** | A number entry field. Chromium-only role. |
| 40 | `PasswordInput` | `lib.rs:113` | none | **none** | A password entry field. Chromium-only role. |
| 41 | `PhoneNumberInput` | `lib.rs:114` | none | **none** | A telephone number entry field. Chromium-only role. |
| 42 | `UrlInput` | `lib.rs:115` | none | **none** | A URL entry field. Chromium-only role. |
| 43 | `Abbr` | `lib.rs:117` | none | **none** | An abbreviation, that is, an abbreviated form of a word or phrase. |
| 44 | `Alert` | `lib.rs:118` | ARIA 1.2 | `alert` | A type of live region with important, and usually time-sensitive, information. See related alertdialog and status. |
| 45 | `AlertDialog` | `lib.rs:119` | ARIA 1.2 | `alertdialog` | A type of dialog that contains an alert message, where initial focus goes to an element within the dialog. See related alert and dialog. |
| 46 | `Application` | `lib.rs:120` | ARIA 1.2 | `application` | A structure containing one or more focusable elements requiring user input, such as keyboard or gesture events, that do not follow a standard interaction pattern supported by a widget role. |
| 47 | `Article` | `lib.rs:121` | ARIA 1.2 | `article` | A section of a page that consists of a composition that forms an independent part of a document, page, or site. |
| 48 | `Audio` | `lib.rs:122` | none | **none** | An audio element. |
| 49 | `Banner` | `lib.rs:123` | ARIA 1.2 | `banner` | A landmark that contains mostly site-oriented content, rather than page-specific content. |
| 50 | `Blockquote` | `lib.rs:124` | ARIA 1.2 | `blockquote` | A section of content that is quoted from another source. |
| 51 | `Canvas` | `lib.rs:125` | none | **none** | A graphics canvas. |
| 52 | `Caption` | `lib.rs:126` | ARIA 1.2 | `caption` | Visible content that names, and may also describe, a figure, table, grid, or treegrid. |
| 53 | `Caret` | `lib.rs:127` | none | **none** | The insertion point inside an editable text control. |
| 54 | `Code` | `lib.rs:128` | ARIA 1.2 | `code` | A section whose content represents a fragment of computer code. |
| 55 | `ColorWell` | `lib.rs:129` | none | **none** | A control that opens a colour picker. |
| 56 | `ComboBox` | `lib.rs:130` | ARIA 1.2 | `combobox` | An input that controls another element, such as a listbox or grid, that can dynamically pop up to help the user set the value of the input. |
| 57 | `EditableComboBox` | `lib.rs:131` | ARIA 1.2 | `combobox` | An ARIA combobox whose text field is editable. |
| 58 | `Complementary` | `lib.rs:132` | ARIA 1.2 | `complementary` | A landmark that is designed to be complementary to the main content at a similar level in the DOM hierarchy, but remaining meaningful when separated from the main content. |
| 59 | `Comment` | `lib.rs:133` | ARIA 1.3 | `comment` | A comment contains content expressing reaction to other content. |
| 60 | `ContentDeletion` | `lib.rs:134` | ARIA 1.2 | `deletion` | A deletion contains content that is marked as removed or content that is being suggested for removal. See related insertion. |
| 61 | `ContentInsertion` | `lib.rs:135` | ARIA 1.2 | `insertion` | An insertion contains content that is marked as added or content that is being suggested for addition. See related deletion. |
| 62 | `ContentInfo` | `lib.rs:136` | ARIA 1.2 | `contentinfo` | A landmark that contains information about the parent document. |
| 63 | `Definition` | `lib.rs:137` | ARIA 1.2 | `definition` | A definition of a term or concept. See related term. |
| 64 | `DescriptionList` | `lib.rs:138` | none | **none** | A description list, that is, a list of terms and their definitions. Chromium-only role. |
| 65 | `Details` | `lib.rs:139` | ARIA 1.2 | `group` | A disclosure widget. ARIA has no dedicated role. |
| 66 | `Dialog` | `lib.rs:140` | ARIA 1.2 | `dialog` | A dialog is a descendant window of the primary window of a web application. For HTML pages, the primary application window is the entire web document, i.e., the body element. |
| 67 | `DisclosureTriangle` | `lib.rs:141` | none | **none** | A triangle that shows and hides content. Chromium-only role. |
| 68 | `Document` | `lib.rs:142` | ARIA 1.2 | `document` | An element containing content that assistive technology users may want to browse in a reading mode. |
| 69 | `EmbeddedObject` | `lib.rs:143` | none | **none** | An embedded foreign document such as a PDF. |
| 70 | `Emphasis` | `lib.rs:144` | ARIA 1.2 | `emphasis` | One or more emphasized characters. See related strong. |
| 71 | `Feed` | `lib.rs:145` | ARIA 1.2 | `feed` | A scrollable list of articles where scrolling may cause articles to be added to or removed from either end of the list. |
| 72 | `FigureCaption` | `lib.rs:146` | ARIA 1.2 | `caption` | Visible content that names, and may also describe, a figure, table, grid, or treegrid. |
| 73 | `Figure` | `lib.rs:147` | ARIA 1.2 | `figure` | A perceivable section of content that typically contains a graphical document, images, code snippets, or example text. The parts of a figure MAY be user-navigable. |
| 74 | `Footer` | `lib.rs:148` | ARIA 1.2 | `contentinfo` | A landmark that contains information about the parent document. |
| 75 | `Form` | `lib.rs:149` | ARIA 1.2 | `form` | A landmark region that contains a collection of items and objects that, as a whole, combine to create a form. See related search. |
| 76 | `Grid` | `lib.rs:150` | ARIA 1.2 | `grid` | A composite widget containing a collection of one or more rows with one or more cells where some or all cells in the grid are focusable by using methods of two-dimensional navigation, such as directional arrow keys. |
| 77 | `GridCell` | `lib.rs:151` | ARIA 1.2 | `gridcell` | A cell in a grid or treegrid. |
| 78 | `Group` | `lib.rs:152` | ARIA 1.2 | `group` | A set of user interface objects that is not intended to be included in a page summary or table of contents by assistive technologies. |
| 79 | `Header` | `lib.rs:153` | ARIA 1.2 | `banner` | A landmark that contains mostly site-oriented content, rather than page-specific content. |
| 80 | `Heading` | `lib.rs:154` | ARIA 1.2 | `heading` | A heading for a section of the page. |
| 81 | `Iframe` | `lib.rs:155` | none | **none** | An inline frame. |
| 82 | `IframePresentational` | `lib.rs:156` | none | **none** | An inline frame whose content must be hidden from assistive technology. |
| 83 | `ImeCandidate` | `lib.rs:157` | none | **none** | A candidate word from an input method editor. |
| 84 | `Keyboard` | `lib.rs:158` | none | **none** | A keyboard or key row. Chromium-only role. |
| 85 | `Legend` | `lib.rs:159` | none | **none** | The caption of a fieldset or a figure. Chromium-only role. |
| 86 | `LineBreak` | `lib.rs:160` | none | **none** | A hard line break inside text. Chromium-only role. |
| 87 | `ListBox` | `lib.rs:161` | ARIA 1.2 | `listbox` | A widget that allows the user to select one or more items from a list of choices. See related combobox and list. |
| 88 | `Log` | `lib.rs:162` | ARIA 1.2 | `log` | A type of live region where new information is added in meaningful order and old information may disappear. See related marquee. |
| 89 | `Main` | `lib.rs:163` | ARIA 1.2 | `main` | A landmark containing the main content of a document. |
| 90 | `Mark` | `lib.rs:164` | ARIA 1.3 | `mark` | Content which is marked or highlighted for reference or notation purposes, due to the content's relevance in the enclosing context. |
| 91 | `Marquee` | `lib.rs:165` | ARIA 1.2 | `marquee` | A type of live region where non-essential information changes frequently. See related log. |
| 92 | `Math` | `lib.rs:166` | ARIA 1.2 | `math` | Content that represents a mathematical expression. |
| 93 | `MenuBar` | `lib.rs:167` | ARIA 1.2 | `menubar` | A presentation of menu that usually remains visible and is usually presented horizontally. |
| 94 | `MenuItemCheckBox` | `lib.rs:168` | ARIA 1.2 | `menuitemcheckbox` | A menuitem with a checkable state whose possible values are true, false, or mixed. |
| 95 | `MenuItemRadio` | `lib.rs:169` | ARIA 1.2 | `menuitemradio` | A checkable menuitem in a set of elements with the same role, only one of which can be checked at a time. |
| 96 | `MenuListPopup` | `lib.rs:170` | none | **none** | The popup list of a native select element. Chromium-only role. |
| 97 | `Meter` | `lib.rs:171` | ARIA 1.2 | `meter` | An element that represents a scalar measurement within a known range, or a fractional value. See related progressbar. |
| 98 | `Navigation` | `lib.rs:172` | ARIA 1.2 | `navigation` | A landmark containing a collection of navigational elements (usually links) for navigating the document or related documents. |
| 99 | `Note` | `lib.rs:173` | ARIA 1.2 | `note` | A section whose content is parenthetic or ancillary to the main content of the resource. |
| 100 | `PluginObject` | `lib.rs:174` | none | **none** | A plugin object. Chromium-only role. |
| 101 | `ProgressIndicator` | `lib.rs:175` | ARIA 1.2 | `progressbar` | An element that displays the progress status for tasks that take a long time. |
| 102 | `RadioGroup` | `lib.rs:176` | ARIA 1.2 | `radiogroup` | A group of radio buttons. |
| 103 | `Region` | `lib.rs:177` | ARIA 1.2 | `region` | A landmark containing content that is relevant to a specific, author-specified purpose and sufficiently important that users will likely want to be able to navigate to the section easily and to have it listed in a summary of the page. Such a page summary could be generated dynamically by a user agent or assistive technology. |
| 104 | `RootWebArea` | `lib.rs:178` | ARIA 1.2 | `document` | The root of a web document. Chromium calls it RootWebArea; ARIA uses document. |
| 105 | `Ruby` | `lib.rs:179` | none | **none** | A ruby annotation base. Chromium-only role. |
| 106 | `RubyAnnotation` | `lib.rs:180` | none | **none** | The text in a ruby annotation. Chromium-only role. |
| 107 | `ScrollBar` | `lib.rs:181` | ARIA 1.2 | `scrollbar` | A graphical object that controls the scrolling of content within a viewing area, regardless of whether the content is fully displayed within the viewing area. |
| 108 | `ScrollView` | `lib.rs:182` | none | **none** | A scrollable container. Chromium-only role. |
| 109 | `Search` | `lib.rs:183` | ARIA 1.2 | `search` | A landmark region that contains a collection of items and objects that, as a whole, combine to create a search facility. See related form and searchbox. |
| 110 | `Section` | `lib.rs:184` | ARIA 1.2 | `region` | A landmark containing content that is relevant to a specific, author-specified purpose and sufficiently important that users will likely want to be able to navigate to the section easily and to have it listed in a summary of the page. Such a page summary could be generated dynamically by a user agent or assistive technology. |
| 111 | `SectionFooter` | `lib.rs:185` | ARIA 1.3 | `sectionfooter` | A set of user interface objects and information representing information about its closest ancestral content group. For instance, a sectionfooter can include information about who wrote the specific section of content, such as an article. It can contain links to related documents, copyright information or other indices and colophon specific to the current section of the page. |
| 112 | `SectionHeader` | `lib.rs:186` | ARIA 1.3 | `sectionheader` | A set of user interface objects and information that represents a collection of introductory items for the element's closest ancestral content group. For instance, a sectionheader can include the heading, introductory statement and related meta data for a section of content, for instance a region or article, within a web page. |
| 113 | `Slider` | `lib.rs:187` | ARIA 1.2 | `slider` | An input where the user selects a value from within a given range. |
| 114 | `SpinButton` | `lib.rs:188` | ARIA 1.2 | `spinbutton` | A form of range that expects the user to select from among discrete choices. |
| 115 | `Splitter` | `lib.rs:189` | ARIA 1.2 | `separator` | A divider that separates and distinguishes sections of content or groups of menuitems. |
| 116 | `Status` | `lib.rs:190` | ARIA 1.2 | `status` | A type of live region whose content is advisory information for the user but is not important enough to justify an alert, often but not necessarily presented as a status bar. |
| 117 | `Strong` | `lib.rs:191` | ARIA 1.2 | `strong` | Content that is important, serious, or urgent. See related emphasis. |
| 118 | `Suggestion` | `lib.rs:192` | ARIA 1.3 | `suggestion` | A single proposed change to content. |
| 119 | `SvgRoot` | `lib.rs:193` | none | **none** | The root element of an SVG document. Chromium-only role. |
| 120 | `Tab` | `lib.rs:194` | ARIA 1.2 | `tab` | A grouping label providing a mechanism for selecting the tab content that is to be rendered to the user. |
| 121 | `TabList` | `lib.rs:195` | ARIA 1.2 | `tablist` | A list of tab elements, which are references to tabpanel elements. |
| 122 | `TabPanel` | `lib.rs:196` | ARIA 1.2 | `tabpanel` | A container for the resources associated with a tab, where each tab is contained in a tablist. |
| 123 | `Term` | `lib.rs:197` | ARIA 1.2 | `term` | A word or phrase with a corresponding definition. See related definition. |
| 124 | `Time` | `lib.rs:198` | ARIA 1.2 | `time` | An element that represents a specific point in time. |
| 125 | `Timer` | `lib.rs:199` | ARIA 1.2 | `timer` | A type of live region containing a numerical counter which indicates an amount of elapsed time from a start point, or the time remaining until an end point. |
| 126 | `TitleBar` | `lib.rs:200` | none | **none** | The title bar of a window. Chromium-only role. |
| 127 | `Toolbar` | `lib.rs:201` | ARIA 1.2 | `toolbar` | A collection of commonly used function buttons or controls represented in compact visual form. |
| 128 | `Tooltip` | `lib.rs:202` | ARIA 1.2 | `tooltip` | A contextual popup that displays a description for an element. |
| 129 | `Tree` | `lib.rs:203` | ARIA 1.2 | `tree` | A widget that allows the user to select one or more items from a hierarchically organized collection. |
| 130 | `TreeGrid` | `lib.rs:204` | ARIA 1.2 | `treegrid` | A grid whose rows can be expanded and collapsed in the same manner as for a tree. |
| 131 | `Video` | `lib.rs:205` | none | **none** | A video element. |
| 132 | `WebView` | `lib.rs:206` | none | **none** | A WebKit web view. Chromium-only role. |
| 133 | `Window` | `lib.rs:207` | ARIA 1.2 | `window (abstract in 1.2; removed in 1.3)` | A window. ARIA 1.2 lists window as an abstract role that authors must not use; ARIA 1.3 removes it. |
| 134 | `PdfActionableHighlight` | `lib.rs:209` | none | **none** | A clickable highlight rectangle inside a PDF. Chromium-only role. |
| 135 | `PdfRoot` | `lib.rs:210` | ARIA 1.2 | `document` | The root of a PDF document. Chromium-only role. |
| 136 | `GraphicsDocument` | `lib.rs:214` | WAI-ARIA Graphics Module 1.0 | `graphics-document` | A type of document in which the visual appearance or layout of content conveys meaning. |
| 137 | `GraphicsObject` | `lib.rs:215` | WAI-ARIA Graphics Module 1.0 | `graphics-object` | A section of a graphics-document that represents a distinct object or sub-component with semantic meaning. |
| 138 | `GraphicsSymbol` | `lib.rs:216` | WAI-ARIA Graphics Module 1.0 | `graphics-symbol` | A graphical object used to convey a simple meaning or category, where the meaning is more important than the particular visual appearance. |
| 139 | `DocAbstract` | `lib.rs:220` | DPUB-ARIA 1.0 | `doc-abstract` | A short summary of the principle ideas, concepts and conclusions of the work, or of a section or excerpt within it. |
| 140 | `DocAcknowledgements` | `lib.rs:221` | DPUB-ARIA 1.0 | `doc-acknowledgments` | A section or statement that acknowledges significant contributions by persons, organizations, governments and other entities to the realization of the work. |
| 141 | `DocAfterword` | `lib.rs:222` | DPUB-ARIA 1.0 | `doc-afterword` | A closing statement from the author or a person of importance, typically providing insight into how the content came to be written, its significance, or related events that have transpired since its timeline. |
| 142 | `DocAppendix` | `lib.rs:223` | DPUB-ARIA 1.0 | `doc-appendix` | A section of supplemental information located after the primary content that informs the content but is not central to it. |
| 143 | `DocBackLink` | `lib.rs:224` | DPUB-ARIA 1.0 | `doc-backlink` | A link that allows the user to return to a related location in the content (e.g., from a footnote to its reference or from a glossary definition to where a term is used). |
| 144 | `DocBiblioEntry` | `lib.rs:225` | DPUB-ARIA 1.0 | `doc-biblioentry` | A single reference to an external source in a bibliography. A biblioentry typically provides more detailed information than its reference(s) in the content (e.g., full title, author(s), publisher, publication date, etc.). |
| 145 | `DocBibliography` | `lib.rs:226` | DPUB-ARIA 1.0 | `doc-bibliography` | A list of external references cited in the work, which may be to print or digital sources. |
| 146 | `DocBiblioRef` | `lib.rs:227` | DPUB-ARIA 1.0 | `doc-biblioref` | A reference to a bibliography entry. |
| 147 | `DocChapter` | `lib.rs:228` | DPUB-ARIA 1.0 | `doc-chapter` | A major thematic section of content in a work. |
| 148 | `DocColophon` | `lib.rs:229` | DPUB-ARIA 1.0 | `doc-colophon` | A short section of production notes particular to the edition (e.g., describing the typeface used), often located at the end of a work. |
| 149 | `DocConclusion` | `lib.rs:230` | DPUB-ARIA 1.0 | `doc-conclusion` | A concluding section or statement that summarizes the work or wraps up the narrative. |
| 150 | `DocCover` | `lib.rs:231` | DPUB-ARIA 1.0 | `doc-cover` | An image that sets the mood or tone for the work and typically includes the title and author. |
| 151 | `DocCredit` | `lib.rs:232` | DPUB-ARIA 1.0 | `doc-credit` | An acknowledgment of the source of integrated content from third-party sources, such as photos. Typically identifies the creator, copyright and any restrictions on reuse. |
| 152 | `DocCredits` | `lib.rs:233` | DPUB-ARIA 1.0 | `doc-credits` | A collection of credits. |
| 153 | `DocDedication` | `lib.rs:234` | DPUB-ARIA 1.0 | `doc-dedication` | An inscription at the front of the work, typically addressed in tribute to one or more persons close to the author. |
| 154 | `DocEndnote` | `lib.rs:235` | DPUB-ARIA 1.0 | `doc-endnote` | One of a collection of notes that occur at the end of a work, or a section within it, that provides additional context to a referenced passage of text. |
| 155 | `DocEndnotes` | `lib.rs:236` | DPUB-ARIA 1.0 | `doc-endnotes` | A collection of notes at the end of a work or a section within it. |
| 156 | `DocEpigraph` | `lib.rs:237` | DPUB-ARIA 1.0 | `doc-epigraph` | A quotation set at the start of the work or a section that establishes the theme or sets the mood. |
| 157 | `DocEpilogue` | `lib.rs:238` | DPUB-ARIA 1.0 | `doc-epilogue` | A concluding section of narrative that wraps up or comments on the actions and events of the work, typically from a future perspective. |
| 158 | `DocErrata` | `lib.rs:239` | DPUB-ARIA 1.0 | `doc-errata` | A set of corrections discovered after initial publication of the work, sometimes referred to as corrigenda. |
| 159 | `DocExample` | `lib.rs:240` | DPUB-ARIA 1.0 | `doc-example` | An illustratration of a key concept of the work, such as a code listing, case study or problem. |
| 160 | `DocFootnote` | `lib.rs:241` | DPUB-ARIA 1.0 | `doc-footnote` | Ancillary information, such as a citation or commentary, that provides additional context to a referenced passage of text. |
| 161 | `DocForeword` | `lib.rs:242` | DPUB-ARIA 1.0 | `doc-foreword` | An introductory section that precedes the work, typically not written by the author of the work. |
| 162 | `DocGlossary` | `lib.rs:243` | DPUB-ARIA 1.0 | `doc-glossary` | A brief dictionary of new, uncommon or specialized terms used in the content. |
| 163 | `DocGlossRef` | `lib.rs:244` | DPUB-ARIA 1.0 | `doc-glossref` | A reference to a glossary definition. |
| 164 | `DocIndex` | `lib.rs:245` | DPUB-ARIA 1.0 | `doc-index` | A navigational aid that provides a detailed list of links to key subjects, names and other important topics covered in the work. |
| 165 | `DocIntroduction` | `lib.rs:246` | DPUB-ARIA 1.0 | `doc-introduction` | A preliminary section that typically introduces the scope or nature of the work. |
| 166 | `DocNoteRef` | `lib.rs:247` | DPUB-ARIA 1.0 | `doc-noteref` | A reference to a footnote or endnote, typically appearing as a superscripted number or symbol in the main body of text. |
| 167 | `DocNotice` | `lib.rs:248` | DPUB-ARIA 1.0 | `doc-notice` | Notifies the user of consequences that might arise from an action or event. Examples include warnings, cautions and dangers. |
| 168 | `DocPageBreak` | `lib.rs:249` | DPUB-ARIA 1.0 | `doc-pagebreak` | A separator denoting the position before which a break occurs between two contiguous pages in a statically paginated version of the content. |
| 169 | `DocPageFooter` | `lib.rs:250` | none | **none found** | A running page footer inside a PDF. No definition for doc-pagefooter was found in DPUB-ARIA 1.0 or in the DPUB-AAM 1.0 role mapping table. |
| 170 | `DocPageHeader` | `lib.rs:251` | none | **none found** | A running page header inside a PDF. No definition for doc-pageheader was found in DPUB-ARIA 1.0 or in the DPUB-AAM 1.0 role mapping table. |
| 171 | `DocPageList` | `lib.rs:252` | DPUB-ARIA 1.0 | `doc-pagelist` | A navigational aid that provides a list of links to the pagebreaks in the content. |
| 172 | `DocPart` | `lib.rs:253` | DPUB-ARIA 1.0 | `doc-part` | A major structural division in a work that contains a set of related sections dealing with a particular subject, narrative arc or similar encapsulated theme. |
| 173 | `DocPreface` | `lib.rs:254` | DPUB-ARIA 1.0 | `doc-preface` | An introductory section that precedes the work, typically written by the author of the work. |
| 174 | `DocPrologue` | `lib.rs:255` | DPUB-ARIA 1.0 | `doc-prologue` | An introductory section that sets the background to a work, typically part of the narrative. |
| 175 | `DocPullquote` | `lib.rs:256` | DPUB-ARIA 1.0 | `doc-pullquote` | A distinctively placed or highlighted quotation from the current content designed to draw attention to a topic or highlight a key point. |
| 176 | `DocQna` | `lib.rs:257` | DPUB-ARIA 1.0 | `doc-qna` | A section of content structured as a series of questions and answers, such as an interview or list of frequently asked questions. |
| 177 | `DocSubtitle` | `lib.rs:258` | DPUB-ARIA 1.0 | `doc-subtitle` | An explanatory or alternate title for the work, or a section or component within it. |
| 178 | `DocTip` | `lib.rs:259` | DPUB-ARIA 1.0 | `doc-tip` | Helpful information that clarifies some aspect of the content or assists in its comprehension. |
| 179 | `DocToc` | `lib.rs:260` | DPUB-ARIA 1.0 | `doc-toc` | A navigational aid that provides an ordered list of links to the major sectional headings in the content. A table of contents may cover an entire work, or only a smaller section of it. |
| 180 | `ListGrid` | `lib.rs:265` | ARIA 1.2 | `grid` | The source doc comment states it behaves like an ARIA grid but exists for Chromium TableView. |
| 181 | `Terminal` | `lib.rs:270` | none | **none** | A multi-line document with VT-100 terminal behaviour. Chromium-only role. |

### 1.2 Totals and roles with no ARIA equivalent

| Count | What |
|---|---|
| 182 | total `Role` variants, discriminants 0 to 181 |
| 89 | roles that name a WAI-ARIA 1.2 role |
| 6 | roles that name a role first defined in WAI-ARIA 1.3: `Comment`, `Image`, `Mark`, `SectionFooter`, `SectionHeader`, `Suggestion` |
| 39 | roles named `doc-*` from DPUB-ARIA 1.0 |
| 3 | roles from the WAI-ARIA Graphics Module 1.0 |
| 45 | roles with **no** equivalent found in any of the four specifications |

The five rows sum to 182. Of the 89 ARIA 1.2 rows, one is `Window`, whose ARIA
1.2 role is abstract and which ARIA 1.3 removes.

The 45 roles with no ARIA equivalent are:

`Unknown`, `TextRun`, `Label`, `ListMarker`, `MenuListOption`,
`LayoutTableCell`, `LayoutTableRow`, `LayoutTable`, `DateInput`,
`DateTimeInput`, `WeekInput`, `MonthInput`, `TimeInput`, `EmailInput`,
`NumberInput`, `PasswordInput`, `PhoneNumberInput`, `UrlInput`, `Abbr`,
`Audio`, `Canvas`, `Caret`, `ColorWell`, `DescriptionList`,
`DisclosureTriangle`, `EmbeddedObject`, `Iframe`, `IframePresentational`,
`ImeCandidate`, `Keyboard`, `Legend`, `LineBreak`, `MenuListPopup`,
`PluginObject`, `Ruby`, `RubyAnnotation`, `ScrollView`, `SvgRoot`,
`TitleBar`, `Video`, `WebView`, `PdfActionableHighlight`, `Terminal`,
`DocPageFooter`, `DocPageHeader`.

Three facts about that list matter for the port.

1. Most of them are Chromium-specific roles that have no web equivalent. The
   source says so in places: `lib.rs:262`-`lib.rs:264` explains that `ListGrid`
   exists for Chromium's `TableView`, and `lib.rs:267`-`lib.rs:269` explains
   that `Terminal` signals VT-100 behaviour. The other Chromium roles carry no
   doc comment, which means their only definition is the enum variant name.
   `[INFERENCE]` The port must accept these names as opaque identifiers. It
   cannot derive their meaning from ARIA, because ARIA does not define them.
2. `DocPageFooter` and `DocPageHeader` have **no** definition anywhere I could
   reach. `grep -o 'doc-[a-z]*'` over the downloaded DPUB-ARIA 1.0 returns 44
   strings, none of which is `doc-pagefooter` or `doc-pageheader`
   (`dpub-aria.html`). The same search over DPUB-AAM 1.0 (`dpub.html`) returns
   zero hits. The DPUB-ARIA role index has exactly 39 role definitions, and
   AccessKit has 41 `Doc*` roles. The two missing ones are these.
3. `Window` maps to an ARIA 1.2 role that the specification marks abstract.
   `https://www.w3.org/TR/wai-aria-1.2/#window` lists `window` in the role
   index, and ARIA 1.3 removes it (the roles dropped between the two documents
   are `command`, `composite`, `input`, `landmark`, `range`, `roletype`,
   `section`, `sectionhead`, `select`, `structure`, `widget`, `window`).
   `[INFERENCE]` A port must not emit `role="window"` to a web consumer; it
   must map to `application` or `group`.

The source cites two external specifications by URL inside the enum itself:

- `lib.rs:212`-`lib.rs:213` — `https://rawgit.com/w3c/graphics-aam/master/#mapping_role_table`
- `lib.rs:218`-`lib.rs:219` — `https://www.w3.org/TR/dpub-aam-1.0/#mapping_role_table`

The first URL uses `rawgit`, a service that no longer exists. The live
equivalent is `https://www.w3.org/TR/graphics-aam-1.0/`, which exists and
defines a role mapping table. The port must cite the W3C URL, not the rawgit
one.

---

## 2. Properties

A `Node` carries three kinds of state (`lib.rs:1107`-`lib.rs:1113`):

```rust
pub struct Node {
    role: Role,
    actions: u32,
    child_actions: u32,
    flags: u32,
    properties: Properties,
}
```

- `role`, `actions`, `child_actions` and `flags` are fixed-size integers.
- Everything else lives in `Properties`, which is `lib.rs:1071`-`lib.rs:1074`:
  a `PropertyIndices` array of 87 bytes and a `Vec<PropertyValue>`.

`Flag` (`lib.rs:801`-`lib.rs:820`) has **18** variants. Each one occupies one
bit of `flags`, set with `Flag::mask` (`lib.rs:822`-`lib.rs:826`).

`PropertyId` (`lib.rs:893`-`lib.rs:1009`) has **87** real variants,
discriminants 0 through 86, plus `Unset` at `lib.rs:1008`, whose discriminant is
87 and whose doc comment says `// This MUST be last.`
`PropertyIndices([u8; PropertyId::Unset as usize])` at `lib.rs:1062` is
therefore `[u8; 87]`.

Public properties total **105**: 18 flags plus 87 stored properties.

`PropertyValue` (`lib.rs:856`-`lib.rs:886`) has **29** variants, listed in
`impl Clone for PropertyValue` at `lib.rs:1011`-`lib.rs:1044`:
`None`, `NodeIdVec`, `NodeId`, `String`, `F64`, `F32`, `Usize`, `Color`,
`TextDecoration`, `LengthVec`, `CoordVec`, `Bool`, `Invalid`, `Toggled`,
`Live`, `TextDirection`, `Orientation`, `SortDirection`, `AriaCurrent`,
`AutoComplete`, `HasPopup`, `ListStyle`, `TextAlign`, `VerticalOffset`,
`Affine`, `Rect`, `TextSelection`, `CustomActionVec`, `TreeId`.

### 2.0 Which roles accept a property

The Rust type system accepts **every** property on **every** role. There is no
role check anywhere in `Node`. The only place a role appears in a property
contract is inside a doc comment. Three doc comments name a role:

| Property | Named role | path:line |
|---|---|---|
| `value` | `Role::Label`, `Role::TextRun` | `lib.rs:2100`, `lib.rs:2114`-`lib.rs:2115` |
| `size_of_set` | `Role::ListBox` | `lib.rs:2296` |
| `position_in_set` | `Role::ListBoxOption` | `lib.rs:2304` |
| `color_value` | `Role::ColorWell` | `lib.rs:2317` |

Every "Roles named in the doc comment" column below is this list. Where the
column reads `-`, the Rust type accepts all 182 roles and the documentation
places no restriction. This is a finding, not a gap: the port must not invent a
role-to-property type constraint that upstream does not have, and it must not
reject a node because a property is set on an unexpected role.

### 2.1 to 2.13 Property groups

Each table lists one `PropertyValue` group. "Id" is the `PropertyId`
discriminant, or the literal `bit` for the 18 flags, which live in `flags` and
have no `PropertyId`.

### 2.1 Flags (stored in the `flags: u32` bit mask)

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| bit | `Hidden` | `lib.rs:1919` | `bool` | `set_*` / `clear_*` | - | Whether this node and its descendants are excluded from the tree presented to assistive technologies and from hit testing. |
| bit | `Multiselectable` | `lib.rs:1924` | `bool` | `set_*` / `clear_*` | - | Whether users may select more than one selectable descendant. |
| bit | `Required` | `lib.rs:1929` | `bool` | `set_*` / `clear_*` | - | Whether user input or selection is required on this node. |
| bit | `Visited` | `lib.rs:1931` | `bool` | `set_*` / `clear_*` | - | Whether this node represents a link that has been visited. |
| bit | `Busy` | `lib.rs:1936` | `bool` | `set_*` / `clear_*` | - | Whether this node is being modified and updates should be withheld until it is ready. |
| bit | `LiveAtomic` | `lib.rs:1941` | `bool` | `set_*` / `clear_*` | - | Whether updates to this live region should be presented as a whole. |
| bit | `Modal` | `lib.rs:1945` | `bool` | `set_*` / `clear_*` | - | Whether this dialog is modal. |
| bit | `TouchTransparent` | `lib.rs:1948` | `bool` | `set_*` / `clear_*` | - | Whether touches pass through this node when a screen reader is in touch exploration mode, as they normally do on a virtual keyboard. |
| bit | `ReadOnly` | `lib.rs:1953` | `bool` | `set_*` / `clear_*` | - | Whether this text widget permits focus and selection but not editing. |
| bit | `Disabled` | `lib.rs:1958` | `bool` | `set_*` / `clear_*` | - | Whether this control or group of controls is unavailable for interaction. |
| bit | `Italic` | `lib.rs:1960` | `bool` | `set_*` / `clear_*` | - | Whether this node's text is italic. |
| bit | `ClipsChildren` | `lib.rs:1962` | `bool` | `set_*` / `clear_*` | - | Whether this node clips child content outside its bounds. |
| bit | `IsLineBreakingObject` | `lib.rs:1964` | `bool` | `set_*` / `clear_*` | - | Whether this node causes a hard line break. |
| bit | `IsPageBreakingObject` | `lib.rs:1966` | `bool` | `set_*` / `clear_*` | - | Whether this node causes a page break. |
| bit | `IsSpellingError` | `lib.rs:1968` | `bool` | `set_*` / `clear_*` | - | Whether this node's text is marked as a spelling error. |
| bit | `IsGrammarError` | `lib.rs:1970` | `bool` | `set_*` / `clear_*` | - | Whether this node's text is marked as a grammar error. |
| bit | `IsSearchMatch` | `lib.rs:1972` | `bool` | `set_*` / `clear_*` | - | Whether this node represents text matching the current search. |
| bit | `IsSuggestion` | `lib.rs:1974` | `bool` | `set_*` / `clear_*` | - | Whether this node's text is a suggested replacement. |

### 2.2 NodeIdVec relations

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 0 | `Children` | `lib.rs:2028` | `Option<&[NodeId]>` | typed setter, see `property_methods!` | - | The ordered list of this node's direct children in the tree. The order should match the intended reading and navigation order. |
| 1 | `Controls` | `lib.rs:2033` | `Option<&[NodeId]>` | typed setter, see `property_methods!` | - | The nodes whose contents or presence are controlled by this node. |
| 2 | `Details` | `lib.rs:2042` | `Option<&[NodeId]>` | typed setter, see `property_methods!` | - | The nodes that provide detailed, structured descriptions for this node and that users may navigate to. Use Node::described_by when a plain-text description is sufficient. |
| 3 | `DescribedBy` | `lib.rs:2048` | `Option<&[NodeId]>` | typed setter, see `property_methods!` | - | The nodes whose contents provide a plain-text description for this node. Use Node::details for structured content that users may need to navigate. |
| 4 | `FlowTo` | `lib.rs:2053` | `Option<&[NodeId]>` | typed setter, see `property_methods!` | - | The nodes that follow this node in an alternate reading order. |
| 5 | `LabelledBy` | `lib.rs:2057` | `Option<&[NodeId]>` | typed setter, see `property_methods!` | - | The nodes that label this node. |
| 6 | `Owns` | `lib.rs:2063` | `Option<&[NodeId]>` | typed setter, see `property_methods!` | - | Nodes owned by this node that are not already its descendants in the tree. This property is unnecessary for direct children or other descendants. |
| 7 | `RadioGroup` | `lib.rs:2066` | `Option<&[NodeId]>` | typed setter, see `property_methods!` | - | For a radio button, the list of all radio buttons in the same group, including this node. |

### 2.3 NodeId relations

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 8 | `ActiveDescendant` | `lib.rs:2075` | `Option<NodeId>` | typed setter, see `property_methods!` | - | For a composite widget such as a listbox, tree, or grid, identifies the currently active descendant. Used when focus remains on the container while the active item changes. |
| 9 | `ErrorMessage` | `lib.rs:2081` | `Option<NodeId>` | typed setter, see `property_methods!` | - | The node that provides an error message for this node. This should normally be used with Node::invalid. |
| 10 | `InPageLinkTarget` | `lib.rs:2084` | `Option<NodeId>` | typed setter, see `property_methods!` | - | The target of this link when it points to another location in the same document. |
| 11 | `MemberOf` | `lib.rs:2086` | `Option<NodeId>` | typed setter, see `property_methods!` | - | The group to which this node belongs. |
| 12 | `NextOnLine` | `lib.rs:2089` | `Option<NodeId>` | typed setter, see `property_methods!` | - | The next text run on the same visual line. The target's Node::previous_on_line should point back to this node. |
| 13 | `PreviousOnLine` | `lib.rs:2092` | `Option<NodeId>` | typed setter, see `property_methods!` | - | The previous text run on the same visual line. The target's Node::next_on_line should point back to this node. |
| 14 | `PopupFor` | `lib.rs:2094` | `Option<NodeId>` | typed setter, see `property_methods!` | - | The node for which this node is a popup. |

### 2.4 String properties

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 15 | `Label` | `lib.rs:2104` | `Option<&str>` | `impl Into<String>` | `Role::Label` | The label of this node. If the label is specified via the Node::labelled_by relation, this doesn't need to be set. The text content of a node with the Role::Label role should be provided vi [doc truncated] |
| 16 | `Description` | `lib.rs:2109` | `Option<&str>` | `impl Into<String>` | - | Additional information that supplements this node's label. |
| 17 | `Value` | `lib.rs:2118` | `Option<&str>` | `impl Into<String>` | `Role::Label`, `Role::TextRun` | The text content or string value of this node. |
| 18 | `AccessKey` | `lib.rs:2126` | `Option<&str>` | `impl Into<String>` | - | A single character, usually part of this node's name, that can be pressed, possibly along with a platform-specific modifier, to perform this node's default action. For menu items, the access key is [doc truncated] |
| 19 | `AuthorId` | `lib.rs:2129` | `Option<&str>` | `impl Into<String>` | - | A way for application authors to identify this node for automated testing purposes. The value must be unique among this node's siblings. |
| 20 | `ClassName` | `lib.rs:2131` | `Option<&str>` | `impl Into<String>` | - | The platform control class name for this node. |
| 21 | `FontFamily` | `lib.rs:2134` | `Option<&str>` | `impl Into<String>` | - | The font family used for this node's text. Only set this when it differs from the parent. |
| 22 | `HtmlId` | `lib.rs:2140` | `Option<&str>` | `impl Into<String>` | - | The ID of the HTML element represented by this node. On platforms where both are mapped to the same platform property, this takes precedence over author_id. |
| 23 | `HtmlTag` | `lib.rs:2142` | `Option<&str>` | `impl Into<String>` | - | The name of the HTML element represented by this node. |
| 24 | `InnerHtml` | `lib.rs:2145` | `Option<&str>` | `impl Into<String>` | - | Inner HTML of an element. Only used for a top-level math element, to support third-party math accessibility products that parse MathML. |
| 25 | `KeyboardShortcut` | `lib.rs:2152` | `Option<&str>` | `impl Into<String>` | - | A keystroke or sequence of keystrokes, complete with any required modifiers(s), that will perform this node's default action. The value of this property should be in a human-friendly format. |
| 26 | `Language` | `lib.rs:2155` | `Option<&str>` | `impl Into<String>` | - | An [IETF language tag](https://www.rfc-editor.org/info/bcp47). Only set this when it differs from the parent. |
| 27 | `Placeholder` | `lib.rs:2161` | `Option<&str>` | `impl Into<String>` | - | A short hint that helps the user with data entry when the node has no Node::value. This property should not be used instead of Node::label. |
| 28 | `RoleDescription` | `lib.rs:2168` | `Option<&str>` | `impl Into<String>` | - | An optional string that may override an assistive technology's description of the node's role. Only provide this for custom control types. The value should be human-friendly and localized. |
| 29 | `StateDescription` | `lib.rs:2173` | `Option<&str>` | `impl Into<String>` | - | An optional string that may override an assistive technology's description of the node's state, replacing default strings such as "checked" or "selected". Note that most platform accessibility APIs [doc truncated] |
| 30 | `Tooltip` | `lib.rs:2178` | `Option<&str>` | `impl Into<String>` | - | If a node's only label comes from a tooltip, it should be exposed through this property rather than label. |
| 31 | `Url` | `lib.rs:2180` | `Option<&str>` | `impl Into<String>` | - | The target URL of a link. |
| 32 | `RowIndexText` | `lib.rs:2185` | `Option<&str>` | `impl Into<String>` | - | A human-readable alternative to the numeric row index. |
| 33 | `ColumnIndexText` | `lib.rs:2190` | `Option<&str>` | `impl Into<String>` | - | A human-readable alternative to the numeric column index. |
| 34 | `BrailleLabel` | `lib.rs:2197` | `Option<&str>` | `impl Into<String>` | - | An alternative to Node::label that assistive technologies may present on a Braille display instead of speaking it. The value is ordinary text, not Unicode Braille characters. |
| 35 | `BrailleRoleDescription` | `lib.rs:2204` | `Option<&str>` | `impl Into<String>` | - | An alternative to Node::role_description that assistive technologies may present on a Braille display instead of speaking it. The value is ordinary text, not Unicode Braille characters. |

### 2.5 f64 properties

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 36 | `ScrollX` | `lib.rs:2209` | `Option<f64>` | typed setter, see `property_methods!` | - | The current horizontal scroll position of this scrollable container. |
| 37 | `ScrollXMin` | `lib.rs:2211` | `Option<f64>` | typed setter, see `property_methods!` | - | The minimum horizontal scroll position of this scrollable container. |
| 38 | `ScrollXMax` | `lib.rs:2213` | `Option<f64>` | typed setter, see `property_methods!` | - | The maximum horizontal scroll position of this scrollable container. |
| 39 | `ScrollY` | `lib.rs:2215` | `Option<f64>` | typed setter, see `property_methods!` | - | The current vertical scroll position of this scrollable container. |
| 40 | `ScrollYMin` | `lib.rs:2217` | `Option<f64>` | typed setter, see `property_methods!` | - | The minimum vertical scroll position of this scrollable container. |
| 41 | `ScrollYMax` | `lib.rs:2219` | `Option<f64>` | typed setter, see `property_methods!` | - | The maximum vertical scroll position of this scrollable container. |
| 42 | `NumericValue` | `lib.rs:2224` | `Option<f64>` | typed setter, see `property_methods!` | - | The current numeric value of this range widget. |
| 43 | `MinNumericValue` | `lib.rs:2229` | `Option<f64>` | typed setter, see `property_methods!` | - | The minimum allowed numeric value of this range widget. |
| 44 | `MaxNumericValue` | `lib.rs:2234` | `Option<f64>` | typed setter, see `property_methods!` | - | The maximum allowed numeric value of this range widget. |
| 45 | `NumericValueStep` | `lib.rs:2237` | `Option<f64>` | typed setter, see `property_methods!` | - | The amount by which the numeric value changes when incremented or decremented by one step. |
| 46 | `NumericValueJump` | `lib.rs:2240` | `Option<f64>` | typed setter, see `property_methods!` | - | The amount by which the numeric value changes for a large increment or decrement. |

### 2.6 f32 properties

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 47 | `FontSize` | `lib.rs:2245` | `Option<f32>` | typed setter, see `property_methods!` | - | Font size is in pixels. |
| 48 | `FontWeight` | `lib.rs:2248` | `Option<f32>` | typed setter, see `property_methods!` | - | Font weight can take on any arbitrary numeric value. Increments of 100 in range `[0, 900]` represent keywords such as light, normal, bold, etc. |

### 2.7 usize properties

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 49 | `RowCount` | `lib.rs:2256` | `Option<usize>` | typed setter, see `property_methods!` | - | The total number of rows in a table, grid, or tree grid. |
| 50 | `ColumnCount` | `lib.rs:2261` | `Option<usize>` | typed setter, see `property_methods!` | - | The total number of columns in a table, grid, or tree grid. |
| 51 | `RowIndex` | `lib.rs:2269` | `Option<usize>` | typed setter, see `property_methods!` | - | The row index of this node within a table, grid, or tree grid. |
| 52 | `ColumnIndex` | `lib.rs:2277` | `Option<usize>` | typed setter, see `property_methods!` | - | The column index of this node within a table, grid, or tree grid. |
| 53 | `RowSpan` | `lib.rs:2282` | `Option<usize>` | typed setter, see `property_methods!` | - | The number of rows spanned by a cell or grid cell. |
| 54 | `ColumnSpan` | `lib.rs:2287` | `Option<usize>` | typed setter, see `property_methods!` | - | The number of columns spanned by a cell or grid cell. |
| 55 | `Level` | `lib.rs:2295` | `Option<usize>` | typed setter, see `property_methods!` | - | The hierarchical level of this node within a structure. |
| 56 | `SizeOfSet` | `lib.rs:2303` | `Option<usize>` | typed setter, see `property_methods!` | `Role::ListBox` | For containers like Role::ListBox, specifies the total number of items. |
| 57 | `PositionInSet` | `lib.rs:2313` | `Option<usize>` | typed setter, see `property_methods!` | `Role::ListBoxOption` | For items like Role::ListBoxOption, specifies their index in the item list. This must be less than the value of size_of_set as set on the container. |

### 2.8 Color properties

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 58 | `ColorValue` | `lib.rs:2318` | `Option<Color>` | typed setter, see `property_methods!` | `Role::ColorWell` | For Role::ColorWell, specifies the selected color. |
| 59 | `BackgroundColor` | `lib.rs:2320` | `Option<Color>` | typed setter, see `property_methods!` | - | Background color. |
| 60 | `ForegroundColor` | `lib.rs:2322` | `Option<Color>` | typed setter, see `property_methods!` | - | Foreground color. |

### 2.9 TextDecoration properties

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 61 | `Overline` | `lib.rs:2327` | `Option<TextDecoration>` | typed setter, see `property_methods!` | - | The style and color of the overline applied to this node's text. |
| 62 | `Strikethrough` | `lib.rs:2329` | `Option<TextDecoration>` | typed setter, see `property_methods!` | - | The style and color of the strikethrough applied to this node's text. |
| 63 | `Underline` | `lib.rs:2331` | `Option<TextDecoration>` | typed setter, see `property_methods!` | - | The style and color of the underline applied to this node's text. |

### 2.10 LengthVec properties

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 64 | `CharacterLengths` | `lib.rs:2353` | `&[u8]` | typed setter, see `property_methods!` | - | For text runs, the length (non-inclusive) of each character in UTF-8 code units (bytes). The sum of these lengths must equal the length of value, also in bytes. A character is defined as the s [doc truncated] |
| 65 | `WordStarts` | `lib.rs:2384` | `&[u8]` | typed setter, see `property_methods!` | - | For text runs, the start index of each word in characters, as defined in character_lengths. This list must be sorted. If this text run doesn't contain the start of any words, but only the midd [doc truncated] |

### 2.11 CoordVec properties

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 66 | `CharacterPositions` | `lib.rs:2404` | `Option<&[f32]>` | typed setter, see `property_methods!` | - | For text runs, this is the position of each character within the node's bounding box, in the direction given by text_direction, in the coordinate space of this node. When present, the length o [doc truncated] |
| 67 | `CharacterWidths` | `lib.rs:2424` | `Option<&[f32]>` | typed setter, see `property_methods!` | - | For text runs, this is the advance width of each character, in the direction given by text_direction, in the coordinate space of this node. When present, the length of this slice should be the [doc truncated] |

### 2.12 Bool properties

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 68 | `Expanded` | `lib.rs:2435` | `Option<bool>` | typed setter, see `property_methods!` | - | Whether this node is expanded, collapsed, or neither. |
| 69 | `Selected` | `lib.rs:2449` | `Option<bool>` | typed setter, see `property_methods!` | - | Indicates whether this node is selected or unselected. |

### 2.13 Unique-enum properties

| Id | Rust name | path:line | Getter returns | Setter takes | Roles named in the doc comment | Meaning |
|---|---|---|---|---|---|---|
| 70 | `Invalid` | `lib.rs:2457` | `Option<Invalid>` | typed setter, see `property_methods!` | - | Whether this node's input is invalid, and whether the error is related to spelling or grammar. |
| 71 | `Toggled` | `lib.rs:2467` | `Option<Toggled>` | typed setter, see `property_methods!` | - | The checked or pressed state of a toggle control. |
| 72 | `Live` | `lib.rs:2472` | `Option<Live>` | typed setter, see `property_methods!` | - | The priority with which updates to this live region should be announced. |
| 73 | `TextDirection` | `lib.rs:2474` | `Option<TextDirection>` | typed setter, see `property_methods!` | - | The direction in which this node's text is laid out. |
| 74 | `Orientation` | `lib.rs:2479` | `Option<Orientation>` | typed setter, see `property_methods!` | - | Whether this node is oriented horizontally or vertically. |
| 75 | `SortDirection` | `lib.rs:2484` | `Option<SortDirection>` | typed setter, see `property_methods!` | - | The direction in which items are sorted by this row or column header. |
| 76 | `AriaCurrent` | `lib.rs:2489` | `Option<AriaCurrent>` | typed setter, see `property_methods!` | - | Whether and how this node represents the current item within a set. |
| 77 | `AutoComplete` | `lib.rs:2494` | `Option<AutoComplete>` | typed setter, see `property_methods!` | - | How predictions are presented while the user enters text. |
| 78 | `HasPopup` | `lib.rs:2499` | `Option<HasPopup>` | typed setter, see `property_methods!` | - | The type of interactive popup that can be triggered by this node. |
| 79 | `ListStyle` | `lib.rs:2501` | `Option<ListStyle>` | typed setter, see `property_methods!` | - | The list marker style. Only available on list items. |
| 80 | `TextAlign` | `lib.rs:2503` | `Option<TextAlign>` | typed setter, see `property_methods!` | - | How this node's text is aligned horizontally. |
| 81 | `VerticalOffset` | `lib.rs:2505` | `Option<VerticalOffset>` | typed setter, see `property_methods!` | - | Whether this node's text is rendered as subscript or superscript. |

### 2.14 The four remaining stored properties

`property_methods!` at `lib.rs:2508`-`lib.rs:2546` declares four properties
that do not fit the generated groups. All four accept every role.

| Id | Rust name | path:line | Rust type (declared at) | Setter takes | Meaning |
|---|---|---|---|---|---|
| 82 | `Transform` | `lib.rs:2521` | `Affine`, `accesskit/src/geometry.rs:22` | `impl Into<Box<Affine>>` | An affine transform applied to the coordinates of this node and its descendants, including `bounds`. |
| 83 | `Bounds` | `lib.rs:2533` | `Rect`, `accesskit/src/geometry.rs:337` | `Rect` | The bounding box of this node, in the node's own coordinate space. |
| 84 | `TextSelection` | `lib.rs:2536` | `TextSelection`, `lib.rs:784` | `impl Into<Box<TextSelection>>` | The current selection or caret position within this node's text. |
| 86 | `TreeId` | `lib.rs:2545` | `TreeId`, `lib.rs:745` | `TreeId` | The tree that this node grafts. See section 6. |

The `CustomActions` property (`lib.rs:2681`, `PropertyId` discriminant 85) is
declared by `vec_property_methods!` at `lib.rs:2679`. Its type is
`Vec<CustomAction>` and `CustomAction` is `lib.rs:761`-`lib.rs:764`: an `i32`
id and a `String` description.

Two ordering rules matter for a port:

- `character_lengths` (`lib.rs:2353`) is a `Vec<u8>` of per-character byte
  lengths. `lib.rs:2336`-`lib.rs:2337` states that the sum of the lengths must
  equal the length of `value` in bytes.
- `word_starts` (`lib.rs:2384`) must be sorted. `lib.rs:2356` says "This list
  must be sorted."

Two index rules differ from ARIA, and both are stated in the source:

| Property | ARIA | AccessKit | path:line |
|---|---|---|---|
| `row_index` | `aria-rowindex` is one-based | zero-based | `lib.rs:2265`-`lib.rs:2266` |
| `column_index` | `aria-colindex` is one-based | zero-based | `lib.rs:2273`-`lib.rs:2274` |
| `level` | `aria-level` is one-based | zero-based | `lib.rs:2291`-`lib.rs:2292` |
| `position_in_set` | `aria-posinset` is one-based | zero-based | `lib.rs:2308`-`lib.rs:2309` |
| `size_of_set` | `aria-setsize` is set on each item | set on the container | `lib.rs:2299`-`lib.rs:2300` |

### 2.15 Property support by the three adapters

The adapters do not fill in every property. This table records what each one
reads or writes, with `path:line`.

| Property | macOS | Windows | AT-SPI |
|---|---|---|---|
| `label` | `accesskit_consumer` `label` read into `accessibilityTitle`, `adapters/macos/src/node.rs:325`, exposed at `node.rs:534`-`node.rs:541` | `UIA_NamePropertyId`, `adapters/windows/src/node.rs:1310`, built at `node.rs:404`-`node.rs:409` | `Accessible.Name`, `adapters/atspi-common/src/node.rs:38`, D-Bus property at `adapters/unix/src/atspi/interfaces/accessible.rs:36` |
| `description` | `accessibilityHelp`, `adapters/macos/src/node.rs:543`-`node.rs:550`, source read at `node.rs:337` | `UIA_FullDescriptionPropertyId`, `adapters/windows/src/node.rs:1311`, built at `node.rs:415` | `Accessible.Description`, `adapters/atspi-common/src/node.rs:46`, D-Bus at `accessible.rs:41` |
| `placeholder` | `accessibilityPlaceholderValue`, `adapters/macos/src/node.rs:552`-`node.rs:559` | `UIA_HelpTextPropertyId`, `adapters/windows/src/node.rs:1313`, built at `node.rs:427`-`node.rs:429` | `GetAttributes` key `"placeholder-text"`, `adapters/atspi-common/src/node.rs:420` |
| `value` | `accessibilityValue`, `adapters/macos/src/node.rs:561`-`node.rs:578`, chosen at `node.rs:344`-`node.rs:365` | `UIA_ValueValuePropertyId`, `adapters/windows/src/node.rs:1346` | no string value; only `Value.CurrentValue` as `f64`, `adapters/atspi-common/src/node.rs:589`, served at `node.rs:1772` |
| `html_id` | `AXDOMIdentifier`, `adapters/macos/src/node.rs:1097`-`node.rs:1098` | `UIA_AutomationIdPropertyId`, `adapters/windows/src/node.rs:1320`, falls back to `author_id` at `node.rs:557`-`node.rs:558` | `GetAttributes` key `"id"`, `adapters/atspi-common/src/node.rs:428`-`node.rs:429` |
| `braille_label` | `AXBrailleLabel`, `adapters/macos/src/node.rs:1093`-`node.rs:1094` | not present in the Windows adapter | `GetAttributes` key `"braillelabel"`, `adapters/atspi-common/src/node.rs:431`-`node.rs:432` |
| `braille_role_description` | `AXBrailleRoleDescription`, `adapters/macos/src/node.rs:1095`-`node.rs:1096` | not present in the Windows adapter | `GetAttributes` key `"brailleroledescription"`, `adapters/atspi-common/src/node.rs:434`-`node.rs:435` |
| `toggled` | `accessibilityValue` as `Value::Bool`, `adapters/macos/src/node.rs:345`-`node.rs:346` | `UIA_ToggleToggleStatePropertyId`, `adapters/windows/src/node.rs:1334` | `State::Checked` / `State::Pressed` / `State::Indeterminate`, `adapters/atspi-common/src/node.rs:367`-`node.rs:374` |
| `selected` | `accessibilitySelected` via `Action::Click`, `adapters/macos/src/node.rs:1081` | `ISelectionItemPattern::IsSelected`, `adapters/windows/src/node.rs:1383` | `State::Selected`, `adapters/atspi-common/src/node.rs:350` |
| `position_in_set` | not present | `UIA_SelectionItemPattern` plus `node.rs:691` `size_of_set_from_container` | `GetAttributes` key `"posinset"`, `adapters/atspi-common/src/node.rs:422`-`node.rs:423`, one-based conversion at `node.rs:396` |
| `size_of_set` | not present | `node.rs:691` | `GetAttributes` key `"setsize"`, `adapters/atspi-common/src/node.rs:425`-`node.rs:426` |
| `expanded` | not present | `UIA_ExpandCollapseExpandCollapseStatePropertyId`, `adapters/windows/src/node.rs:1486` | not present |

`not present` means a targeted search of the named file found no occurrence. It
does not mean the native API lacks the concept.

---

## 3. Relations

### 3.1 The parent relation does not exist as a property

There is no `parent` property. A parent is **derived** from the `children`
list of another node. `accesskit_consumer` builds the reverse index when it
applies a `TreeUpdate`:

```rust
for (child_index, child_id) in node_data.children().iter().enumerate() {
    let mapped_child_id = map_id(*child_id);
    if !seen_child_ids.insert(mapped_child_id) {
        panic!("TreeUpdate includes duplicate child {:?}", child_id);
    }
    let parent_and_index = ParentAndIndex(node_id, child_index);
```

`accesskit_consumer/src/tree.rs:233`-`tree.rs:239`. The stored value is
`Option<ParentAndIndex>`, read back at `accesskit_consumer/src/node.rs:126`-`node.rs:131`
and dereferenced by `parent()` at `accesskit_consumer/src/node.rs:133`-`node.rs:136`.

Three rules follow directly from that code:

| Rule | Evidence |
|---|---|
| The index of a child is its position in the parent's `children` vector. | `tree.rs:233` (`enumerate()`), `tree.rs:239` |
| The root node has no parent. | `tree.rs:262`-`tree.rs:264` sets `parent_and_index = None` when `local_node_id == root` |
| A `NodeId` may appear at most once across all `children` lists in one update. | `tree.rs:235`-`tree.rs:237` panics on a duplicate |

### 3.2 Child relations

| Aspect | Value | path:line |
|---|---|---|
| Property | `children`, `PropertyId` discriminant 0 | `lib.rs:895`, declared at `lib.rs:2028` |
| Rust type | `Vec<NodeId>`, getter `&[NodeId]`, plus `push_child` | `lib.rs:2021`, `lib.rs:1351` |
| Ordering rule | "The order should match the intended reading and navigation order." | `lib.rs:2026`-`lib.rs:2027` |
| Consumer iterator | `DoubleEndedIterator + ExactSizeIterator` | `accesskit_consumer/src/node.rs:168`-`node.rs:179` |
| Graft exception | A graft node's only child comes from its subtree, not from `children`. | `accesskit_consumer/src/node.rs:161`-`node.rs:179`; enforced at `tree.rs:272`-`tree.rs:278` |

`TreeUpdate` documents the ordering rule again from the sender's side: to
remove a child and all of its descendants, the list must include an updated
version of the parent node with the child's ID removed from `Node::children`
(`lib.rs:3225`-`lib.rs:3228`).

### 3.3 Sibling relations

There is no sibling property either. Siblings are computed by walking the
parent's `children` list: `following_sibling_ids`
(`accesskit_consumer/src/node.rs:196`-`node.rs:200`), and the filtered form
`following_filtered_siblings` (`node.rs:210`-`node.rs:213`). `FilteredChildren`
and `FollowingSiblings` skip nodes that the caller's filter rejects
(`node.rs:189`-`node.rs:194`). All three adapters pass the same filter function:
`adapters/macos/src/node.rs:32` imports `crate::filters::filter`,
`adapters/windows/src/node.rs:33` imports `crate::filters::{filter,
filter_with_root_exception}`, and `adapters/atspi-common/src/node.rs:30`
imports `crate::filters::filter`.

The consequence for the port: sibling identity is not a stored fact. A parent
whose `children` list is `[a, b, c]` gives `a` the following siblings `[b, c]`.
A node that appears in no `children` list has no siblings, even if it appears
in `owns` or `controls`.

### 3.4 Non-structural relations

Fifteen properties point at other nodes. None of them affects the tree shape,
and none imposes an ordering rule except `children` and the two `*_on_line`
properties, which are required to point in both directions.

| Relation | Kind | ARIA | path:line |
|---|---|---|---|
| `children` | list | none | `lib.rs:2028` |
| `controls` | list | `aria-controls` | `lib.rs:2033` |
| `details` | list | `aria-details` | `lib.rs:2042` |
| `described_by` | list | `aria-describedby` | `lib.rs:2048` |
| `flow_to` | list | `aria-flowto` | `lib.rs:2053` |
| `labelled_by` | list | `aria-labelledby` | `lib.rs:2057` |
| `owns` | list | `aria-owns` | `lib.rs:2063` |
| `radio_group` | list | none | `lib.rs:2066` |
| `active_descendant` | single | `aria-activedescendant` | `lib.rs:2075` |
| `error_message` | single | `aria-errormessage` | `lib.rs:2081` |
| `in_page_link_target` | single | none | `lib.rs:2084` |
| `member_of` | single | none | `lib.rs:2086` |
| `next_on_line` | single | none | `lib.rs:2089` |
| `previous_on_line` | single | none | `lib.rs:2092` |
| `popup_for` | single | none | `lib.rs:2094` |

Two differences from ARIA are called out in the source:

- `details` may reference more than one node, while `aria-details` references
  one (`lib.rs:2038`-`lib.rs:2039`).
- `next_on_line` and `previous_on_line` must be mutual: "The target's
  `Node::previous_on_line` should point back to this node" (`lib.rs:2088`),
  and the same statement in reverse at `lib.rs:2091`.

`owns` has an explicit exclusion: "This property is unnecessary for direct
children or other descendants" (`lib.rs:2059`-`lib.rs:2060`). A port must not
use `owns` to rebuild the tree, because `accesskit_consumer` does not: only
`children` feeds `ParentAndIndex` (`accesskit_consumer/src/tree.rs:233`).

### 3.5 Tree and node identity

| Concept | Rust type | path:line | Rule |
|---|---|---|---|
| `NodeId` | `pub struct NodeId(pub NodeIdContent)` where `NodeIdContent = u64` | `lib.rs:703`, `lib.rs:715` | Unique within one tree only. `lib.rs:705`-`lib.rs:710` says the pair (`NodeId`, `TreeId`) is globally unique. |
| `TreeId` | `pub struct TreeId(pub Uuid)` | `lib.rs:745` | `TreeId::ROOT` is the nil UUID (`lib.rs:747`-`lib.rs:750`). |
| `TreeInfo` | struct with `root`, `toolkit_name`, `toolkit_version` | `lib.rs:3169`-`lib.rs:3176` | `root` is required; the two toolkit fields are `Option<String>`. |
| `TreeUpdate` | struct with `nodes`, `tree`, `tree_id`, `focus` | `lib.rs:3208`-`lib.rs:3258` | `focus` must be sent with every update even when unchanged (`lib.rs:3250`-`lib.rs:3252`). |

---

## 4. The node model

### 4.1 Every field of `Node`

`Node` is `lib.rs:1107`-`lib.rs:1113`. All five fields are private. Rust
callers reach them through generated accessors.

| Field | Rust type | path:line | Required | Meaning |
|---|---|---|---|---|
| `role` | `Role` | `lib.rs:1108` | **required** | The node type. `Node::new(role)` at `lib.rs:1828` is the only constructor, and it takes a role. |
| `actions` | `u32` | `lib.rs:1109` | required, defaults to 0 | Bit mask of supported `Action` values, one bit per `Action` (`Action::mask`, `lib.rs:352`-`lib.rs:355`). |
| `child_actions` | `u32` | `lib.rs:1110` | required, defaults to 0 | Bit mask of actions supported by **all** children, added in 0.21.0. |
| `flags` | `u32` | `lib.rs:1111` | required, defaults to 0 | 18 boolean flags, one bit per `Flag` variant. |
| `properties` | `Properties` | `lib.rs:1112` | required, defaults to empty | A `PropertyIndices` of `[u8; 87]` plus a `Vec<PropertyValue>`. `Properties` is `lib.rs:1071`-`lib.rs:1074`. |

`Node` derives `Default` and `PartialEq` (`lib.rs:1102`), and serde with
`deny_unknown_fields` and camelCase renaming (`lib.rs:1103`-`lib.rs:1106`).

### 4.2 Derived state, not fields

The following are queries, not stored data. A port must not add fields for
them.

| Query | path:line | How it is computed |
|---|---|---|
| `parent_id()` | `accesskit_consumer/src/node.rs:126`-`node.rs:131` | Reads the `ParentAndIndex` built from the parent's `children` list. |
| `is_graft()` | `accesskit_consumer/src/node.rs:122`-`node.rs:124` | `tree_id().is_some()`. |
| `index_in_parent` | `accesskit_consumer/src/node.rs:151`-`node.rs:158` | The `usize` stored in `ParentAndIndex`. |
| `parent` | `accesskit_consumer/src/node.rs:133`-`node.rs:136` | Lookup by `parent_id`. Panics via `unwrap` if the parent is absent. |

### 4.3 What changed in 0.23 through 0.25

`accesskit/CHANGELOG.md` is the record. Only the entries below touch the node
model in this range; 0.24.0 changed nothing but the minimum Rust version
(`CHANGELOG.md:44`).

| Release | Changelog entry | Commit | Effect on the node model |
|---|---|---|---|
| 0.23.0 | "Multiple tree support" (`CHANGELOG.md:56`, feature at `CHANGELOG.md:60`) | `c16eb80` | **New field `Node::tree_id`** and the new property `PropertyId::TreeId`. The change is marked breaking (`CHANGELOG.md:53`-`CHANGELOG.md:56`). |
| 0.23.0 | "Store text decoration style and color in a struct" (`CHANGELOG.md:55`, `CHANGELOG.md:70`) | `c2e8487` | Breaking: `overline`, `strikethrough` and `underline` changed from a pair of values to a `TextDecoration` struct (`lib.rs:847`-`lib.rs:850`). |
| 0.23.0 | "Implement the `active_descendant` property" (`CHANGELOG.md:65`) | `863755d` | Bug fix: the property was declared but not wired up. |
| 0.25.0 | "Add html_id node property" (`CHANGELOG.md:19`) | `5332ac0` | **New property `html_id`**, `PropertyId::HtmlId` at `lib.rs:921`, declared at `lib.rs:2140`. The commit touches nine files, including all three platform adapters. |
| 0.25.0 | "Reuse property buffers when cloning nodes" (`CHANGELOG.md:15`, `CHANGELOG.md:30`) | `97194ad` | Breaking performance change to `Clone` only; see section 7. |
| 0.25.0 | "Compare node properties by property ID" (`CHANGELOG.md:25`) | `05ea5c5` | Bug fix: `PartialEq for Properties` compared values by slot position, which is wrong once a clone reuses buffers. Now at `lib.rs:1084`-`lib.rs:1094`. |
| 0.25.0 | "Allow pushing to a previously cleared node property" (`CHANGELOG.md:24`) | `572addd` | Bug fix: `Properties::get_mut` at `lib.rs:1122`-`lib.rs:1136` now re-initialises a cleared slot. |
| 0.25.1 | "Add tree_id node property to the JSON schema" (`CHANGELOG.md:8`) | `1d53dae` | Adds the `tree_id` node property to the generated JSON schema. `tree_id` itself was added in 0.23.0. |

Verification commands and their output:

```
$ git tag --contains c16eb80 | head
accesskit-v0.23.0
accesskit-v0.24.0
accesskit-v0.24.1
accesskit-v0.25.0
accesskit-v0.25.1
$ git tag --contains 97194ad | head
accesskit-v0.25.0
accesskit-v0.25.1
$ git show --stat 5332ac0 | head -20
commit 5332ac0927b7fb78eff6b8b68c21ef4c801aae7c
Author: Arnold Loubriat <datatriny@gmail.com>
Date:   Sun Aug 25 21:04:19 2026 +0200

    feat: Add html_id node property (#776)

 accesskit/src/lib.rs              |  9 +++++++++
 accesskit_consumer/src/node.rs    |  8 ++++++++
 adapters/android/Cargo.toml       |  1 +
 adapters/atspi-common/src/node.rs |  7 +++++++
 adapters/ios/src/node.rs          | 41 ++++++++++++++++++++++++++++++++++++++-
 adapters/macos/src/node.rs        |  6 +++++-
 adapters/unix/Cargo.toml          |  1 +
 adapters/windows/src/node.rs      |  3 ++-
 adapters/winit/Cargo.toml         |  1 +
 9 files changed, 74 insertions(+), 3 deletions(-)
```

So exactly **two** things are new in 0.23 through 0.25: the `tree_id` property
(0.23.0) and the `html_id` property (0.25.0). Everything else in `Node` predates
0.23. Section 6 covers both.

---

## 5. The three platform mappings compared

### 5.1 A correction to the premise of this section

The three adapters do **not** map native roles and properties onto the
AccessKit model. They map the AccessKit model onto the native platform API.
Each adapter is driven by an `accesskit_consumer::NodeRef` and serves an
already-built AccessKit tree to the operating system.

| Adapter | Evidence |
|---|---|
| macOS | `adapters/macos/src/node.rs:16` imports `accesskit_consumer::{FilterResult, FullNodeId, NodeRef, Tree}`. `PlatformNode` is an `NSAccessibilityElement` subclass (`node.rs:402`, `node.rs:404` `const NAME: &'static str = "AccessKitNode"`). `fn role` at `node.rs:502` calls `self.resolve(ns_role)`, and `ns_role` at `node.rs:36` takes a `&NodeRef`. |
| Windows | `adapters/windows/src/node.rs:18` imports `accesskit_consumer`. `fn control_type` at `node.rs:58` takes `&self` on `NodeWrapper` (`impl NodeWrapper<'_>` opens at `node.rs:57`) and reads `self.node.role()` at `node.rs:59`. The file implements UIA provider COM interfaces (`#[implement(...)]` at `node.rs:790`-`node.rs:805`). |
| AT-SPI | `adapters/atspi-common/src/node.rs:15` imports `accesskit_consumer`. `fn role` at `node.rs:87` reads `self.0.role()` at `node.rs:92`. The D-Bus server side lives in `adapters/unix/src/atspi/interfaces/`, which calls into `atspi-common`. |

Consequences the port must respect:

1. The tree is built by the **application**, not by the adapter. There is no
   `UIA_ControlTypeId -> Role` function and no `AXRole -> Role` function
   anywhere in these files.
2. A port that wants to read a native tree and produce AccessKit nodes is
   writing something upstream does not have. `[INFERENCE]` It must own the
   reverse tables itself.
3. The role maps are **total and exhaustive**, which is the property the port
   should copy. The macOS match has 172 arms covering 182 `Role` patterns and
   has no `_` arm (`adapters/macos/src/node.rs:40`-`node.rs:229`). The Windows
   match has 166 arms and no `_` arm (`node.rs:61`-`node.rs:263`). The AT-SPI
   match ends with `Role::Terminal => AtspiRole::Terminal` and a closing brace,
   with no `_` arm (`adapters/atspi-common/src/node.rs:293`-`node.rs:294`).
   `[INFERENCE]` In Zig the same property comes free: a `switch` over an enum
   with every tag covered and no `else` branch is a compile error when a tag is
   added. That is the strongest argument for modelling `Role` as a Zig enum
   rather than a tagged integer.

### 5.2 Role

| Concept | macOS | Windows | AT-SPI |
|---|---|---|---|
| Function | `ns_role`, `adapters/macos/src/node.rs:36` | `control_type`, `adapters/windows/src/node.rs:58` | `role`, `adapters/atspi-common/src/node.rs:87` |
| Scrutinee | `accesskit::Role`, `node.rs:37` | `accesskit::Role`, `node.rs:59` | `accesskit::Role`, `node.rs:92` |
| `Button` | `NSAccessibilityButtonRole`, `node.rs:69` (or `NSAccessibilityCheckBoxRole` at `node.rs:67` when `toggled` is set) | `UIA_ButtonControlTypeId`, `node.rs:92` | `AtspiRole::Button`, `node.rs:107` (or `AtspiRole::ToggleButton` at `node.rs:105`) |
| `CheckBox` | `NSAccessibilityCheckBoxRole`, `node.rs:56` | `UIA_CheckBoxControlTypeId`, `node.rs:77` | `AtspiRole::CheckBox`, `node.rs:114` |
| `RadioButton` | `NSAccessibilityRadioButtonRole`, `node.rs:57` | `UIA_RadioButtonControlTypeId`, `node.rs:78` | `AtspiRole::RadioButton`, `node.rs:227` |
| `TextInput` | `NSAccessibilityTextFieldRole`, `node.rs:64` | `UIA_EditControlTypeId`, `node.rs:91` | `AtspiRole::Entry`, `node.rs:267` (the arm spans `node.rs:261`-`node.rs:267`) |
| `Heading` | `ns_string!("Heading")`, `node.rs:125` | `UIA_TextControlTypeId`, `node.rs:149` | `AtspiRole::Heading`, `node.rs:179` |
| `Link` | `NSAccessibilityLinkRole`, `node.rs:46` | `UIA_HyperlinkControlTypeId`, `node.rs:67` | `AtspiRole::Link`, `node.rs:192` |
| `Table` | `NSAccessibilityTableRole`, `node.rs:78` | `UIA_TableControlTypeId`, `node.rs:98` | `AtspiRole::Table`, `node.rs:254` |
| `Window` | `NSAccessibilityGroupRole`, `node.rs:180` | `UIA_WindowControlTypeId`, `node.rs:215` | `AtspiRole::Frame`, `node.rs:287`, with the reason given at `node.rs:284`-`node.rs:286` |
| `Terminal` | `NSAccessibilityTextAreaRole`, `node.rs:228` | `UIA_DocumentControlTypeId`, `node.rs:138` | `AtspiRole::Terminal`, `node.rs:293` |
| `Unknown` | `NSAccessibilityUnknownRole`, `node.rs:41` | `UIA_CustomControlTypeId`, `node.rs:62` | `AtspiRole::Unknown`, `node.rs:291` |
| Sub-role channel | `ns_sub_role`, `node.rs:244`, 44 arms plus `_ => None` at `node.rs:293`; exposed as `accessibilitySubrole` at `node.rs:508` | none; the control type carries all detail | `AtspiRole::Extended` at `node.rs:89` when the node has a role description |

The macOS adapter is the only one of the three that splits a role into a role
plus a sub-role. `Role::Tab` maps to `NSAccessibilityRadioButtonRole`
(`node.rs:165`) with `NSAccessibilityTabButtonSubrole` (`node.rs:286`). This
is a real modelling problem for a port: `Role` has no sub-role field, so the
split has to live somewhere else.

### 5.3 Name

| Concept | macOS | Windows | AT-SPI |
|---|---|---|---|
| Native selector or property | `accessibilityTitle`, `adapters/macos/src/node.rs:534` | `UIA_NamePropertyId`, `adapters/windows/src/node.rs:1310` | `org.a11y.atspi.Accessible.Name`, `adapters/unix/src/atspi/interfaces/accessible.rs:33` (interface) and `:36` (property) |
| Rust entry point | `fn title`, `adapters/macos/src/node.rs:535` | `fn name`, `adapters/windows/src/node.rs:404` | `fn name`, `adapters/atspi-common/src/node.rs:38` |
| Source expression | `self.0.label()` at `node.rs:325` | `self.node.write_label(&mut result)` at `node.rs:409` | `self.0.label()` at `node.rs:42` |
| Fall-back rule | returns `None` for a root `Window`, `node.rs:317`-`node.rs:320`; returns `None` for `Label`, `ListBoxOption`, `ListMarker`, `MenuListOption` and `TitleBar`, `node.rs:233`-`node.rs:242`, applied at `node.rs:322`-`node.rs:323` | falls back to the window title for the root, `node.rs:1028`-`node.rs:1029` | falls back to the value when `label_comes_from_value()`, `node.rs:39`-`node.rs:41` |
| String conversion | `NSString::from_str`, `node.rs:538` | `WideString::new(self.string_buffer)` plus `write_str`, `node.rs:405`, `node.rs:418` | D-Bus `Str::from(value)`, `adapters/unix/src/atspi/bus.rs:341` |

The `label_comes_from_value()` rule appears in all three adapters:
`adapters/macos/src/node.rs:329`, `adapters/windows/src/node.rs:406`,
`adapters/atspi-common/src/node.rs:39`. `[INFERENCE]` This is not an AccessKit
rule but an adapter convention that resolves a name-versus-value ambiguity, and
a port needs one rule, not three.

### 5.4 Description

| Concept | macOS | Windows | AT-SPI |
|---|---|---|---|
| Native selector or property | `accessibilityHelp`, `adapters/macos/src/node.rs:543` | `UIA_FullDescriptionPropertyId`, `adapters/windows/src/node.rs:1311` | `org.a11y.atspi.Accessible.Description`, `adapters/unix/src/atspi/interfaces/accessible.rs:41` |
| Rust entry point | `fn description`, `adapters/macos/src/node.rs:544` | `fn description`, `adapters/windows/src/node.rs:415` | `fn description`, `adapters/atspi-common/src/node.rs:46` |
| Source expression | `self.0.description()`, `node.rs:337` | `self.node.description()`, `node.rs:416` | `self.0.description()`, `node.rs:47` |
| Second channel | none | `UIA_LocalizedControlTypePropertyId` is bound to `role_description` instead, `node.rs:1308`, built at `node.rs:267`-`node.rs:269` | none; AT-SPI has no `HelpText` member |

`UIA_HelpTextPropertyId` does **not** carry the description on Windows. It is
bound to `placeholder` (`adapters/windows/src/node.rs:1313`), which is the
opposite of what the UIA name suggests. That is a finding a port must copy
exactly, because it is the behaviour users depend on.

### 5.5 Value

| Concept | macOS | Windows | AT-SPI |
|---|---|---|---|
| Native selector or property | `accessibilityValue`, `adapters/macos/src/node.rs:561` | `UIA_ValueValuePropertyId`, `adapters/windows/src/node.rs:1346`; `UIA_RangeValueValuePropertyId`, `node.rs:1357` | `org.a11y.atspi.Value.CurrentValue`, `adapters/unix/src/atspi/interfaces/value.rs:41` |
| Rust entry point | `fn value`, `adapters/macos/src/node.rs:562` | `fn value`, `adapters/windows/src/node.rs:603` | `fn current_value`, `adapters/atspi-common/src/node.rs:1772` |
| Source expression | a four-step chain at `node.rs:344`-`node.rs:365` | `self.node.write_value(&mut result)`, `node.rs:610` | `self.0.numeric_value()`, `node.rs:589` |
| Order of preference | 1. `toggled`, `node.rs:345`; 2. `is_selected` for `Role::Tab`, `node.rs:348`-`node.rs:352`; 3. `label` for the five `label_is_exposed_in_value` roles, `node.rs:353`-`node.rs:357`; 4. `value`, `node.rs:358`; 5. `numeric_value`, `node.rs:361` | one source, gated by `has_value() && !label_comes_from_value()`, `node.rs:596` | one source, `f64` only |
| Value type | `enum Value { Bool(bool), Number(f64), String(String) }`, `adapters/macos/src/node.rs:303`-`node.rs:307` | `BSTR` for `UIA_ValueValuePropertyId`, `f64` for `UIA_RangeValueValuePropertyId`, `node.rs:1346`, `node.rs:1357` | `f64` only, `node.rs:1772` |

Only macOS expresses a string value. Windows expresses a range number through
a second pattern (`UIA_RangeValuePatternId`, `adapters/windows/src/node.rs:1356`,
with `UIA_RangeValueMinimumPropertyId` at `node.rs:1359` and
`UIA_RangeValueMaximumPropertyId` at `node.rs:1360`). AT-SPI has no string
value at all: `GetAttributes` carries `posinset` and `setsize` as strings
(`adapters/atspi-common/src/node.rs:422`-`node.rs:426`) but the value is a
`f64`.

### 5.6 Focusable

No adapter stores a "focusable" boolean. Focusability is a **query** over the
node, and it is answered differently on each platform.

| Concept | macOS | Windows | AT-SPI |
|---|---|---|---|
| Native property | none; no `kAXFocusedAttribute` and no `AXRoleSubrole` in the file | `UIA_IsKeyboardFocusablePropertyId`, `adapters/windows/src/node.rs:1317`; `UIA_HasKeyboardFocusPropertyId`, `node.rs:1318` | `State::Focusable`, `adapters/atspi-common/src/node.rs:317` |
| Rust predicate | `can_be_focused`, `adapters/macos/src/node.rs:298`: `filter(node) == FilterResult::Include && node.role() != Role::Window` | `fn is_focusable`, `adapters/windows/src/node.rs:538`, delegating to `self.node.is_focusable(&filter)` at `node.rs:539` | `state.is_focusable(&filter)`, `adapters/atspi-common/src/node.rs:316` |
| Current focus | `isAccessibilityFocused` and `can_be_focused`, `adapters/macos/src/node.rs:652`-`node.rs:654` | `fn is_focused`, `adapters/windows/src/node.rs:542`; root focus at `node.rs:1165`-`node.rs:1172` | `State::Focused`, `adapters/atspi-common/src/node.rs:385` |
| Setting focus | `Action::Focus`, `adapters/macos/src/node.rs:670` and `node.rs:682` | `Action::Focus`, `adapters/windows/src/node.rs:1130` | `Action::Focus`, `adapters/atspi-common/src/node.rs:1186`, D-Bus `Component.GrabFocus` at `adapters/unix/src/atspi/interfaces/component.rs:63` |
| Also relevant | `accessibilitySubrole`, `accessibilityTitle` and `accessibilityHelp` are always allowed, `adapters/macos/src/node.rs:1306`, `node.rs:1313`, `node.rs:1314` | `UIA_IsContentElementPropertyId` and `UIA_IsControlElementPropertyId` both map to one method, `adapters/windows/src/node.rs:1314`-`node.rs:1315`, defined at `node.rs:433` | `State::Enabled` and `State::Sensitive`, `adapters/atspi-common/src/node.rs:380` |

The macOS predicate is the weakest of the three: it says only "the filter
keeps this node and it is not a window". `filter` is
`accesskit_consumer::FilterResult`, imported from `crate::filters` at
`adapters/macos/src/node.rs:32`.

### 5.7 Text content of a node

| Concept | macOS | Windows | AT-SPI |
|---|---|---|---|
| Plain text | `accessibilityStringForRange:`, `adapters/macos/src/node.rs:840`, body at `node.rs:841`-`node.rs:852` | `ITextProvider::GetSelection`, `ITextProvider::DocumentRange`, `adapters/windows/src/node.rs:1433` and `node.rs:1468` | `org.a11y.atspi.Text.GetText`, `adapters/unix/src/atspi/interfaces/text.rs:47`; Rust entry `fn text`, `adapters/atspi-common/src/node.rs:1459` |
| Attributed text | `accessibilityAttributedStringForRange:`, `adapters/macos/src/node.rs:854`, body at `node.rs:855`-`node.rs:958` | none; UIA has no attributed-text interface | `Text.GetAttributeRun`, `adapters/unix/src/atspi/interfaces/text.rs:130`; Rust entry `text_attribute_run`, `adapters/atspi-common/src/node.rs:1656` |
| Length | not exposed separately | `DocumentRange` end, `adapters/windows/src/node.rs:1468` | `Text.CharacterCount`, `adapters/unix/src/atspi/interfaces/text.rs:28`; Rust entry `character_count`, `adapters/atspi-common/src/node.rs:1415` |
| Caret | `selectedTextRange`, `adapters/macos/src/node.rs:1032` | `SupportedTextSelection`, `adapters/windows/src/node.rs:1475` | `Text.CaretOffset`, `adapters/unix/src/atspi/interfaces/text.rs:33`; Rust entry `caret_offset`, `adapters/atspi-common/src/node.rs:1425` |
| Gate | `node.supports_text_ranges()`, `adapters/macos/src/node.rs:843` | `is_text_pattern_supported`, `adapters/windows/src/node.rs:710`, delegating at `node.rs:711` | `resolve_for_text`, `adapters/atspi-common/src/node.rs:817`, gate at `node.rs:788` |
| Per-character metrics | none; computed by `range.traverse_text`, `adapters/macos/src/node.rs:861` | delegated to `PlatformRange`, `adapters/windows/src/node.rs:34`, implemented in `adapters/windows/src/text.rs` | delegated to accesskit text ranges, `adapters/atspi-common/src/node.rs:1417` |

None of the three adapters builds an AccessKit `TextRun`. Text ranges are
computed from `character_lengths`, `character_positions`, `character_widths`
and `word_starts` at query time, inside `accesskit_consumer`. `Role::TextRun`
exists in the enum but the adapters only map it outward: macOS to
`NSAccessibilityUnknownRole` (`adapters/macos/src/node.rs:42`), Windows to
`UIA_CustomControlTypeId` (`adapters/windows/src/node.rs:63`), AT-SPI to
`AtspiRole::Static` (`adapters/atspi-common/src/node.rs:183`).

### 5.8 Children

| Concept | macOS | Windows | AT-SPI |
|---|---|---|---|
| Selector | `accessibilityChildren`, `adapters/macos/src/node.rs:449`; `accessibilityChildrenInNavigationOrder`, `node.rs:454` | `IRawElementProviderFragment::get_Children`, `adapters/windows/src/node.rs:1148` onward | `Accessible.GetChildren`, `adapters/unix/src/atspi/interfaces/accessible.rs:89`; `GetChildAtIndex`, `accessible.rs:74` |
| Order | the adapter assumes navigation order equals child order, `adapters/macos/src/node.rs:456` | UIA order | AT-SPI order, which is the native order |
| Filter | `node.items(filter)`, `adapters/macos/src/node.rs:468` | `filter(self.node) == FilterResult::Include`, `adapters/windows/src/node.rs:434` | `filter`, `adapters/atspi-common/src/node.rs:319` |

The macOS adapter states the ordering assumption in a comment at
`adapters/macos/src/node.rs:456`: "For now, we assume the children are in
navigation order." The AccessKit `children` list already carries reading and
navigation order (`lib.rs:2026`-`lib.rs:2027`), so the comment describes a
platform detail, not a gap.

---

## 6. Properties added for the web

### 6.1 `html_id`

Added in **0.25.0**, changelog entry "Add html_id node property"
(`accesskit/CHANGELOG.md:19`), commit `5332ac0`, issue #776.

| Aspect | Value | path:line |
|---|---|---|
| Property id | `PropertyId::HtmlId`, discriminant 22 | `lib.rs:921` |
| Declaration | in `string_property_methods!` | `lib.rs:2140` |
| Rust type | `String`, getter `Option<&str>` | `lib.rs:860`, `lib.rs:1449`-`lib.rs:1452` |
| Meaning | "The ID of the HTML element represented by this node." | `lib.rs:2135` |
| Precedence rule | "On platforms where both are mapped to the same platform property, this takes precedence over `author_id`." | `lib.rs:2136`-`lib.rs:2137` |
| ARIA equivalent | none | not in ARIA 1.2 or 1.3 role or property indexes |

Why it was added: `author_id` (`lib.rs:2129`) means "a way for application
authors to identify this node for automated testing purposes", and it must be
unique among siblings. `html_id` means "the `id` attribute of the HTML
element". Web automation needs the second thing. The precedence rule exists
because macOS and Windows each have exactly one native slot for "the
identifier of this element":

- Windows binds `UIA_AutomationIdPropertyId` to `html_id()` and falls back to
  `author_id()` only when `html_id()` is absent
  (`adapters/windows/src/node.rs:555`-`node.rs:558`).
- macOS binds `accessibilityIdentifier` to `author_id` alone
  (`adapters/macos/src/node.rs:526`-`node.rs:532`) and exposes `html_id`
  through a separate, non-standard `AXDOMIdentifier` attribute
  (`adapters/macos/src/node.rs:1097`-`node.rs:1098`).
- AT-SPI puts it in the attributes map under the key `id`
  (`adapters/atspi-common/src/node.rs:428`-`node.rs:429`).

How a port must treat it:

1. It is a plain `Option<String>`. There is no parsing and no validation.
2. `html_id` and `author_id` are both legal at the same time. The Windows
   fallback is one adapter's choice, not a model rule.
3. The AT-SPI key name is the literal lowercase `id`, set at
   `adapters/atspi-common/src/node.rs:429`. That string goes on the D-Bus
   wire inside the `GetAttributes` reply, so it is protocol-visible.

### 6.2 `tree_id`

Added in **0.23.0**, changelog entry "Multiple tree support"
(`accesskit/CHANGELOG.md:56`, feature line `CHANGELOG.md:60`), commit `c16eb80`,
issue #655. Marked a breaking change at `CHANGELOG.md:53`-`CHANGELOG.md:56`.
A separate 0.25.1 entry, "Add tree_id node property to the JSON schema"
(`CHANGELOG.md:8`, commit `1d53dae`), only fixed the generated schema.

| Aspect | Value | path:line |
|---|---|---|
| Property id | `PropertyId::TreeId`, discriminant 86 | `lib.rs:1005` |
| Declaration | in `property_methods!` | `lib.rs:2545` |
| Rust type | `TreeId`, which wraps a `Uuid` | `lib.rs:745` |
| Meaning | "The tree that this node grafts. When set, this node acts as a graft point, and its child is the root of the specified subtree." | `lib.rs:2538`-`lib.rs:2540` |
| Ordering rule | "A graft node must be created before its subtree is pushed." | `lib.rs:2541` |
| Removal rule | "Removing a graft node or clearing this property removes its subtree, unless a new graft node is provided in the same update." | `lib.rs:2543`-`lib.rs:2544` |
| Inconsistency rule | a node with `tree_id` must not have `children` | `accesskit_consumer/src/tree.rs:272`-`tree.rs:278` panics |
| ARIA equivalent | none | not an ARIA concept |

Why it was added: AccessKit 0.22 and earlier had exactly one tree per
adapter. A UI with an embedded document, a popup hosted by another process, or
an out-of-process widget needed more than one. `TreeUpdate` gained a `tree_id`
field (`lib.rs:3246`) and a graft node in the parent tree names the subtree
root.

How a port must treat it:

1. `tree_id` is a node property, not a field of `Node`. It lives in
   `properties` like any other value, and its getter is `Option<TreeId>`
   (`lib.rs:1997`, `lib.rs:2545`).
2. `TreeId::ROOT` is the nil UUID (`lib.rs:749`). It means "the main tree", and
   it is the default for a `TreeUpdate` that does not say otherwise.
3. A graft node has exactly one child, and that child comes from the subtree,
   not from `children`. `accesskit_consumer` bypasses the normal child list for
   graft nodes: `child_ids` returns `ChildIds::Graft`
   (`accesskit_consumer/src/node.rs:171`-`node.rs:173`).
4. The consumer exposes `is_graft()` as a query
   (`accesskit_consumer/src/node.rs:122`-`node.rs:124`).
5. `uuid` is a Rust crate, not a Zig one, and the pinned Zig 0.16.0 standard
   library has no `std.uuid`: `ls lib/std/uuid.zig` reports no such file.
   `[INFERENCE]` A Zig port needs its own 16-byte value type. This document
   records only the size and the nil value.

---

## 7. The Zig type design

**This section is a proposal, not a finding.** Everything in sections 1 to 6
was read from source. Everything here is a design argument that
`docs/30-port-design.md` may accept, change, or reject.

### 7.1 What the Rust model actually is

Restating the shape from the findings, because the design follows from it:

| Part | Count | Rust form | path:line |
|---|---|---|---|
| `Role` | 182 | `#[repr(u8)]` enum | `lib.rs:62` |
| `Action` | 22 | `#[repr(u8)]` enum | `lib.rs:289` |
| `Flag` | 18 | private `#[repr(u8)]` enum | `lib.rs:801` |
| `PropertyId` | 87 plus `Unset` | private `#[repr(u8)]` enum | `lib.rs:893` |
| `PropertyValue` | 29 | private untagged enum | `lib.rs:856` |
| `Node` | 5 fields | `role`, `actions: u32`, `child_actions: u32`, `flags: u32`, `Properties` | `lib.rs:1107` |
| `Properties` | 2 fields | `PropertyIndices([u8; 87])` plus `Vec<PropertyValue>` | `lib.rs:1071` |

The storage trick is `PropertyIndices`: a fixed 87-byte array where each byte
is the slot number of that property inside `values`, and the sentinel `Unset`
(87) means absent (`lib.rs:1062`, `lib.rs:1076`-`lib.rs:1082`). It gives
constant-time lookup and a sparse value array.

### 7.2 Proposed Zig types

```zig
pub const Role = enum(u8) { unknown = 0, text_run = 1, /* ... 182 tags ... */ };

pub const NodeId = struct { value: u64 };

pub const TreeId = struct { bytes: [16]u8 };   // nil bytes == TreeId::ROOT

pub const PropertyId = enum(u8) { children = 0, /* ... 87 tags ... */ };

pub const PropertyValue = union(enum) {
    none,
    node_id_vec: []const NodeId,
    node_id: NodeId,
    string: []const u8,
    f64: f64,
    f32: f32,
    usize: usize,
    color: Color,
    text_decoration: TextDecoration,
    length_vec: []const u8,
    coord_vec: []const f32,
    bool: bool,
    invalid: Invalid,
    toggled: Toggled,
    live: Live,
    text_direction: TextDirection,
    orientation: Orientation,
    sort_direction: SortDirection,
    aria_current: AriaCurrent,
    auto_complete: AutoComplete,
    has_popup: HasPopup,
    list_style: ListStyle,
    text_align: TextAlign,
    vertical_offset: VerticalOffset,
    affine: Affine,
    rect: Rect,
    text_selection: TextSelection,
    custom_action_vec: []const CustomAction,
    tree_id: TreeId,
};
```

Notes on each choice.

1. **Tag values equal the Rust discriminants.** The order is wire-visible
   (section 1.2) and the C header confirms it. Pinning explicit tag values
   makes a fixture recorded against the C header usable directly.
2. **`Role` stays a plain enum, not a union.** A node always has a role, and
   `Node::new` takes one (`lib.rs:1828`). A `union(enum)` would add a tag for
   no benefit.
3. **`PropertyValue` keeps `none` as an explicit tag** rather than relying on a
   Zig optional. Upstream needs the distinction: a cleared property keeps its
   slot and holds `None` (`lib.rs:1148`-`lib.rs:1153`), and a later push must
   see `None` and re-initialise (`lib.rs:1131`-`lib.rs:1133`).
4. **`Affine` is inline, not boxed.** Rust boxes it (`lib.rs:881`) because a
   Rust enum has no layout guarantee. `Affine` is `[f64; 6]`
   (`accesskit/src/geometry.rs:22`), so 48 bytes. `[INFERENCE]` In Zig the
   union is pointer-free by choice, so boxing would add an allocation with no
   size benefit. The cost of inlining is that the union is at least 48 bytes
   wide. The port must measure that, not assume it.
5. **`Rect` inline.** Four `f64` (`geometry.rs:337`-`geometry.rs:345`),
   32 bytes. Rust stores it unboxed already (`lib.rs:882`).
6. **`TextSelection` inline.** Two `TextPosition`, each `{ node: u64,
   character_index: usize }` (`lib.rs:771`-`lib.rs:777`), so 32 bytes on a
   64-bit target. Rust boxes it (`lib.rs:883`) for the same reason as
   `Affine`.
7. **`usize` is kept for the nine index and count properties.** Rust used
   `lib.rs:863`. Keeping `usize` makes the wire mapping a straight cast.
8. **Strings are `[]const u8`, not sentinel-terminated.** A fixture must be
   able to round-trip a string containing any byte.

### 7.3 Storage: three options, one recommendation

| Option | Layout | Lookup | Set a new property | Size per node |
|---|---|---|---|---|
| A. Mirror upstream | `[87]u8` indices plus a dense value array | constant time, one array index | append, amortised constant time | 87 bytes plus values |
| B. Sorted pairs | `[]Property` sorted by id | logarithm, at most 7 comparisons | binary-search insert, a bounded memmove | 2 bytes of ids per property plus values |
| C. Linear scan | `[]PropertyValue` with no ids | linear in the count | append | values only |

**Recommended: B, a sorted array of id and value pairs.**

Reasons, in order of weight.

1. **The 87-byte index array is the dominant cost for sparse nodes.** A
   `Role::TextRun` with `value`, `character_lengths` and `text_direction` has
   three properties. Option A spends 87 bytes on indices. Option B spends 3.
   `[INFERENCE]` In a text-heavy interface most nodes are text runs, so the
   index array dominates. The port must benchmark this rather than trust the
   argument, and `docs/50-verification.md` should carry the benchmark.
2. **Equality becomes correct by construction.** Upstream had to add a
   dedicated fix, "Compare node properties by property ID"
   (`accesskit/CHANGELOG.md:25`, commit `05ea5c5`, code at
   `lib.rs:1084`-`lib.rs:1094`), precisely because a dense layout makes slot
   order differ between two nodes holding the same properties. A sorted pair
   array is compared by walking both in id order, so the port gets the fix for
   free and never has the bug.
3. **Lookup cost is bounded and small.** With at most 87 entries, binary
   search needs at most 7 comparisons. Every property read in the three
   adapters is one lookup: `accessibilityTitle`
   (`adapters/macos/src/node.rs:325`), `UIA_NamePropertyId`
   (`adapters/windows/src/node.rs:1310`), `Accessible.Name`
   (`adapters/atspi-common/src/node.rs:42`). `[INFERENCE]` Option A costs one
   extra dependent load: index into the byte array, then index into the value
   array. Option B costs none.
4. **Insertion is bounded.** A memmove of at most 86 fixed-size entries is a
   fixed upper bound, which is what the house rule asks for. Properties are
   set once at node construction and then only read, so the insert runs once
   per property per node.
5. **Clone is a single pass.** Option B clones by walking the pair array. There
   is no index array to copy separately and no way for the two to go out of
   step.

What option B gives up, stated plainly: a `Node` can no longer be a
fixed-size struct with an inline array, so it needs a slice, so it needs an
allocator, and the allocator must be a parameter. That is already a house
rule, so it costs nothing extra.

```zig
pub const Property = struct {
    id: PropertyId,
    value: PropertyValue,
};

pub const Properties = struct {
    allocator: std.mem.Allocator,
    items: []Property,   // sorted by @intFromEnum(id); no duplicates; no `none`

    pub fn get(self: Properties, id: PropertyId) ?PropertyValue;
    pub fn set(self: *Properties, id: PropertyId, v: PropertyValue) error{OutOfMemory}!void;
    pub fn clear(self: *Properties, id: PropertyId) void;
};
```

Design rules the port must hold to, each traceable to a finding:

| Rule | Why |
|---|---|
| `items` stays sorted by `@intFromEnum(id)` | makes `eql` correct without the 0.25.0 fix |
| `items` never holds `PropertyValue{ .none = {} }` | a cleared property leaves the slice rather than staying as `none` |
| `clear` on an absent id is a no-op, not an error | matches `Properties::clear` (`lib.rs:1148`-`lib.rs:1153`) |
| `push` after `clear` starts a new list | matches the 0.25.0 fix `572addd` (`lib.rs:1131`-`lib.rs:1133`) |
| no per-role validation of properties | section 2.0: the Rust type accepts any property on any role |
| `PropertyId` values never change | section 1.2: the order is wire-visible |

### 7.4 Comparison with the upstream 0.25.0 clone change

The upstream entry is "Reuse property buffers when cloning nodes"
(`accesskit/CHANGELOG.md:15` breaking, `CHANGELOG.md:30` performance), commit
`97194ad`, 170 insertions and 40 deletions in one file. What it changed:

| What | Where now | What it does |
|---|---|---|
| `Clone for Properties::clone_from` | `lib.rs:1164`-`lib.rs:1167` | `source.values.clone_into(&mut self.values)` reuses the destination `Vec` allocation |
| `Clone for PropertyValue::clone_from` | `lib.rs:1046`-`lib.rs:1057` | seven fast paths that call `dest.clone_from(source)` when the variants match, so a `String` or `Vec` keeps its buffer |
| `Clone for Node::clone_from` | `lib.rs:1847`-`lib.rs:1853` | forwards to `properties.clone_from` |
| `PartialEq for Properties` | `lib.rs:1084`-`lib.rs:1094` | added separately, commit `05ea5c5`, because slot reuse broke position-based equality |
| `Properties::get_mut` | `lib.rs:1122`-`lib.rs:1136` | re-initialises a cleared slot, commit `572addd` |

**What the port should keep.**

1. **Buffer reuse on clone.** In Zig, `clone` and `cloneInto` are separate
   functions for exactly this reason. `Node` gains
   `pub fn cloneInto(self: Node, allocator: std.mem.Allocator, out: *Node) error{OutOfMemory}!void`,
   and `Properties` gains the same. The allocator is a parameter, per the house
   rules.
2. **Equality by property id, never by slot.** With option B this is
   structural: both lists are already in id order.
3. **The cleared-then-pushed rule.** With option B a cleared property is gone
   from the slice, so the rule is automatic. The port still needs a test,
   because upstream needed one: `pusher_should_start_a_new_list_after_the_clearer`
   at `lib.rs:1382`.
4. **A byte-level round-trip property.** The port should state it as a
   metamorphic oracle in `docs/50-verification.md`.

**What the port should drop.**

1. The `PropertyIndices` array. It exists to make lookup constant time over a
   dense value array. Option B does not need it.
2. The `Unset` sentinel byte. Option B uses absence from the slice, which is
   the same idea expressed through the type system.
3. `Box<Affine>` and `Box<TextSelection>`. See 7.2 items 4 and 6.

**What the port must not lose.** Rust needed `clone_from` because a `Vec` may
reallocate. In Zig, `cloneInto` exists for the same reason and must be used on
the same path, because `accesskit_consumer` replaces the previous node on
every update. The source states the cost: "for performance, an update should
only include nodes that are new or changed... there is still a cost in
processing these nodes and replacing the previous instances"
(`lib.rs:3198`-`lib.rs:3202`). A port that allocates a fresh pair slice on
every node update loses to upstream on exactly the path upstream optimised.

### 7.5 House rules, checked against this subject

| House rule | How the tree model satisfies or fights it |
|---|---|
| `io` is threaded explicitly, never global | The tree model needs no I/O. Property setters that take strings need an allocator, which is a parameter. |
| State is a parameter, not a capture | `Node` is a value. `NodeRef` is a borrowed view. The port should keep `Node` a plain struct with no back-pointer. |
| Event and platform logic is pure over decoded input | The three role tables in section 5 are exactly pure functions of one decoded value. They are the model for every adapter the port writes. |
| Allocators are parameters | Section 7.3 gives `Properties` an allocator field set at construction. The alternative is passing the allocator to every method. `[INFERENCE]` The integration owner picks; `local://zaccesskit-deps.md` records that goose does the former. |
| Explicit error sets | `Properties.set` returns `error{OutOfMemory}` and nothing else. No other property operation can fail. |
| Loops have fixed upper bounds | The pair array is bounded at 87 by `PropertyId`. Every loop over it gets a `comptime` bound from `@typeInfo(PropertyId).@"enum".fields.len`. |
| No backwards compatibility | The property order is pinned because the **wire format** is pinned, not for source compatibility. `docs/31-c-abi-design.md` owns that argument. |

---

## 8. Test vectors

**This section proposes a fixture format. It is not a finding.** The format
is specified in full so a later document can implement it without inventing
anything.

### 8.1 The constraint

No Rust toolchain may exist, at any point, to check the port. That rules out
generating golden vectors with cargo, and it rules out running the Rust test
suite as an oracle. It does not rule out a recorded fixture: a byte blob copied
once into the repository, plus a decoder written in Zig, is a valid oracle.
The house rules ask for exactly that, in `ozai/AGENTS.md` section 2: "Wire
compatibility is a test, not a comment... a golden-vector test carrying bytes
captured from the Rust implementation".

Two artefacts, with different jobs:

| Artefact | Job | Produced by |
|---|---|---|
| `test/fixtures/tree/<name>.nodejson` | the semantic model: which node has which role, properties and relations | hand-written from the tables in sections 1 and 2, or transcribed from an existing tree dump |
| `test/fixtures/wire/<name>.nodejson.hex` | the byte model: the exact serialised form of the same tree | recorded once, committed, then only read |

Verification reads both. It never regenerates either.

### 8.2 The fixture format

Path: `test/fixtures/tree/<name>.nodejson`. Encoding UTF-8. Line ending LF.
No byte-order mark. The final line ends with LF. The format has no comments.

```
zaccesskit-node-fixture 1
tree_id         00000000-0000-0000-0000-000000000000
root            1
focus           1
toolkit_name    zig-a11y-test
toolkit_version 0.1.0
node_count      3

node 1
    role          window
    actions       none
    child_actions none
    flag          none
    prop label     "Root"
    prop children  [2, 3]

node 2
    role          button
    actions       click focus
    child_actions none
    flag          none
    prop label     "OK"
    prop value     "Cancel"
    prop bounds    { 0x0p+0, 0x0p+0, 0x1.4p+3, 0x1.8p+1 }

node 3
    role          text_run
    actions       none
    child_actions none
    flag          none
    prop value               "Hi"
    prop character_lengths   [1, 1]
    prop character_positions [0x0p+0, 0x1.2p+1]
    prop text_direction      left_to_right
end
```

Grammar, stated exactly.

| Element | Rule |
|---|---|
| Magic | line 1 is the literal `zaccesskit-node-fixture 1` |
| Header keys | `tree_id`, `root`, `focus`, `toolkit_name`, `toolkit_version`, `node_count`, one per line, in that order |
| `tree_id` | 8-4-4-4-12 lowercase hex; the nil UUID means `TreeId::ROOT` (`lib.rs:749`) |
| `root`, `focus`, `node_count` | decimal `u64` |
| `toolkit_name`, `toolkit_version` | quoted string; the empty string means absent |
| Blank line | exactly one blank line between `node` blocks |
| `node <id>` | decimal `u64` at column 0. Node ids must be unique and must cover 1 to `node_count` with no gaps |
| Indent | every line inside a `node` block is indented by exactly 4 spaces |
| `role <name>` | exactly one per node; the lowerCamelCase serde name of the `Role` variant |
| `actions`, `child_actions` | space-separated lowerCamelCase `Action` names in ascending discriminant order; the literal `none` for an empty mask |
| `flag <name>` | one line per set flag, ascending by `Flag` discriminant; the literal `none` for an empty mask |
| `prop <name> <value>` | one line per property. Read order does not matter; the encoder must emit ascending `PropertyId` order |
| Duplicate `prop` | rejected. A node holds each property at most once |
| Unknown name | rejected. Role, action, flag and property names come from fixed tables in the source, never from a fuzzy match |
| `focusable_is_not_a_flag` | rejected by the parser, on purpose. Section 5.6 records that no adapter stores focusability |
| `end` | the literal final line, after the last node block |

Value grammar. The `PropertyId` fixes the `PropertyValue` variant, so the two
must agree or the parser reports a type error naming both.

| `PropertyValue` variant | Syntax | Example |
|---|---|---|
| `NodeIdVec` | `[` id {`,` id} `]`, decimal `u64` | `[2, 3]` |
| `NodeId` | decimal `u64` | `7` |
| `String` | `"` escaped `"` | `"Cancel"` |
| `F64`, `F32` | C99 hex float, or `nan`, `inf`, `-inf` | `0x1.4p+3` |
| `Usize` | decimal | `3` |
| `Color` | `{ 0xRR, 0xGG, 0xBB, 0xAA }` | `{ 0xFF, 0x00, 0x00, 0xFF }` |
| `TextDecoration` | `{ style, 0xRR, 0xGG, 0xBB, 0xAA }`, style one of `solid`, `dotted`, `dashed`, `double`, `wavy` (`lib.rs:695`-`lib.rs:701`) | `{ dotted, 0x00, 0x00, 0x00, 0xFF }` |
| `LengthVec` | `[` decimal `u8` {`,` …} `]` | `[1, 1]` |
| `CoordVec` | `[` hex float {`,` …} `]` | `[0x0p+0, 0x1.2p+1]` |
| `Bool` | `true` or `false` | `true` |
| `Affine` | `{ ` hex float times 6 `}` in `[f64; 6]` order (`geometry.rs:22`) | `{ 0x1p+0, 0x0p+0, 0x0p+0, 0x1p+0, 0x0p+0, 0x0p+0 }` |
| `Rect` | `{ ` hex float times 4 `}` in `x0, y0, x1, y1` order (`geometry.rs:337`) | `{ 0x0p+0, 0x0p+0, 0x1p+0, 0x1p+1 }` |
| `TextSelection` | `{ ` `node` id index `,` `node` id index ` }` | `{ node 3 0, node 3 2 }` |
| `CustomActionVec` | `[` `{` decimal `i32` string `}` {`,` …} `]` | `[{ 0 "first" }]` |
| `TreeId` | 8-4-4-4-12 lowercase hex | `11111111-2222-3333-4444-555555555555` |
| the 12 unique enums | the lowerCamelCase variant name, for example `left_to_right`, `polite`, `menu` | `left_to_right` |

String escapes: `\"`, `\\`, `\n`, `\r`, `\t`, `\0`, and `\xHH` for any other
byte. No `\u` form, because the model is bytes rather than code points. That
matters: `character_lengths` counts UTF-8 bytes
(`lib.rs:2335`-`lib.rs:2337`).

Two choices need justifying. Hex floats round-trip an `f64` bit pattern
exactly through any decimal parser, and keep `-0.0`, `0.0` and `nan`
distinguishable. Decimal `u8` lists match the Rust type of `character_lengths`,
which is `Vec<u8>` (`lib.rs:866`, `lib.rs:1671`).

### 8.3 The byte fixture

`test/fixtures/wire/<name>.nodejson.hex` holds the same tree in the exact
serialised form. One record, no comments:

```
ZAKW 1 <byte-length> <sha256-of-the-bytes-that-follow>
<hex, lowercase, 64 characters per line>
```

`ZAKW 1` is a four-byte magic chosen by the port. It is not an AccessKit
format; it is the fixture container. The digest uses
`std.crypto.sha2.Sha256`, which is at `lib/std/crypto/sha2.zig:23` in the
pinned Zig 0.16.0 tree. The digest covers every byte after the first LF, so a
truncated or edited fixture fails before any parsing starts.

The body is the port's own wire encoding of `TreeInfo` plus `TreeUpdate`.
`docs/31-c-abi-design.md` defines that encoding. Section 8.2 defines only the
container.

### 8.4 What a conformance fixture set must contain

Each row is a separate file. Each row exists because it pins a specific fact
this document records.

| Fixture | Pins |
|---|---|
| `roles_all.nodejson` | 182 nodes, one per role, each with only `role` set. Proves every role name parses and every role enum value round-trips. |
| `role_discriminants.nodejson` | one node per role, with a distinct `author_id` equal to the decimal discriminant. Cross-checks the Zig enum tag values against `lib.rs` and against `include/accesskit.h:283`-`include/accesskit.h:482`. |
| `property_all.nodejson` | 105 nodes, one per public property, each property set alone. Proves every property name and value syntax parses. |
| `flags_all.nodejson` | 18 nodes, one flag each. Proves flag names and order. |
| `text_run.nodejson` | a `Role::TextRun` with `value`, `character_lengths`, `character_positions`, `character_widths`, `word_starts`, `text_direction` and `text_selection`. Proves the byte-count rule at `lib.rs:2336`-`lib.rs:2337` and the sort rule at `lib.rs:2356`. |
| `relations.nodejson` | a parent with three children, plus `owns`, `controls`, `labelled_by`, `described_by`, `details`, `flow_to`, `radio_group`, `active_descendant`, `error_message`, `member_of`, `popup_for`, and a mutual `next_on_line` and `previous_on_line` pair. Proves section 3. |
| `graft.nodejson` | a parent with a `tree_id` graft node, plus a second update with a different `tree_id` and its own `root`. Proves the graft rule at `lib.rs:2541` and the panic condition at `accesskit_consumer/src/tree.rs:272`-`tree.rs:278`. |
| `clear_then_push.nodejson` | a node with `children` set, cleared, then pushed to. Proves the 0.25.0 fix `572addd`. |
| `clone_equivalence.nodejson` | a node with every property kind set, used for the `clone` versus `cloneInto` metamorphic oracle. |
| `numeric_edges.nodejson` | `-0.0`, `0.0`, `nan`, `inf` and `-inf` in `numeric_value`, `bounds` and `font_size`. Proves the hex float round trip. |

### 8.5 The invariants a checker must assert

Each invariant traces to a finding above, so each is checkable rather than
aspirational.

| # | Invariant | Traces to |
|---|---|---|
| 1 | `decode(fixture)` is stable, and `encode(decode(fixture))` is byte-identical to `fixture` | the round-trip property in 7.4 |
| 2 | `cloneInto(decode(fixture))` equals `decode(fixture)` field for field | `lib.rs:1164`-`lib.rs:1167` |
| 3 | Two nodes with the same properties set in different orders compare equal | `CHANGELOG.md:25`, commit `05ea5c5`, `lib.rs:1084`-`lib.rs:1094` |
| 4 | `clear` then `push` yields a list containing only the pushed item | `lib.rs:1131`-`lib.rs:1133`, commit `572addd` |
| 5 | `sum(character_lengths)` equals the byte length of `value` | `lib.rs:2336`-`lib.rs:2337` |
| 6 | `word_starts` is strictly increasing | `lib.rs:2356` |
| 7 | `len(character_positions)` equals `len(character_lengths)` when present | `lib.rs:2392`-`lib.rs:2393` |
| 8 | a node with `tree_id` has no `children` | `accesskit_consumer/src/tree.rs:272`-`tree.rs:278` |
| 9 | the root node has no parent | `accesskit_consumer/src/tree.rs:262`-`tree.rs:264` |
| 10 | no `NodeId` appears twice across all `children` lists in one update | `accesskit_consumer/src/tree.rs:235`-`tree.rs:237` |
| 11 | every `@intFromEnum(role)` and `@intFromEnum(action)` is below the value the fixture records | section 1.2, `include/accesskit.h:283`-`include/accesskit.h:482` |
| 12 | no stored property holds `PropertyValue{ .none = {} }` | 7.3 |

### 8.6 How the fixtures are made without Rust

1. **Author them by hand.** Sections 1 and 2 of this document are the source.
   Every role name, property name and property type in a fixture can be
   checked by eye against a `path:line` here. Nothing needs a generator.
2. **Record the byte fixtures once.** Whoever has a build writes
   `test/fixtures/wire/*.nodejson.hex` once and commits it. From that commit
   on the file is read-only evidence. The Zig checker never writes it.
3. **Cross-check against the C header, not against Rust.**
   `include/accesskit.h` is generated from the same Rust types by
   `cbindgen.toml`, and it carries the 182 role names in the same order.
   Verified: `grep -c 'ACCESSKIT_ROLE_' include/accesskit.h` returns `182`.
   The header is text in the repository, not a Rust build product.
4. **Use the ARIA and AAM tables for direction.** Sections 5.2 to 5.8 already
   carry a `path:line` for every cell, so a reviewer can check a platform
   fixture by reading rather than by running.
5. **Report a missing byte fixture as open.** An absent
   `test/fixtures/wire/` file means the wire encoding is unverified. It belongs
   in `docs/50-verification.md` as an open item, not as a passing test.

---

## Open questions for `docs/30-port-design.md`

| Question | Why this document cannot answer it |
|---|---|
| `std.ArrayList` or a hand-written pair slice | Zig 0.16 marks `std.ArrayListUnmanaged` deprecated at `lib/std/std.zig:59` and `std.array_list.Managed` deprecated at `lib/std/array_list.zig:11`. The standard type costs an allocator field per node; a hand-written slice costs code. |
| A `TreeId` type | Zig 0.16 has no `std.uuid`. `ls lib/std/uuid.zig` reports no such file. The port must write a 16-byte type or pin a package. |
| Whether the property store keeps a `none` tag | 7.3 removes it. If the wire encoding must distinguish cleared from never set, the port has to add it back deliberately. |
| Whether the port implements the reverse role tables | Section 5.1 establishes that upstream has none. A port that reads a native tree needs them, and they are 182 entries per platform. |
