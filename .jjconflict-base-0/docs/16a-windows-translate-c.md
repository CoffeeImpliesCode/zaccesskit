# 16a. Windows via `translate-c`, the fallback appendix

> **Status: superseded as the Windows record, retained as the fallback route.**
> `docs/16-native-platform-apis.md` is the authoritative Windows document. It
> covers the same adapter and more, and it establishes that `zigwin32` binds the
> entire Windows boundary without touching the Windows SDK, which a compile
> probe on Zig 0.16.0 confirmed. This file is kept for one reason: it is the
> only place that records where the MinGW headers actually live and which header
> holds which symbol, which is what a `translate-c` binding would need if
> `zigwin32` were ever abandoned. Its symbol table and adapter analysis are
> redundant; read `docs/16-native-platform-apis.md` for those.

One correction this file records and `docs/16-native-platform-apis.md` does
not: the `Uia*` free functions are **not** in `uiautomationclient.h`. A grep
for `UiaLookupId` there returns nothing. `UiaLookupId` is at
`uiautomationcoreapi.h:522`, `UiaRaiseAutomationEvent` at `:526`,
`UiaReturnRawElementProvider` at `:537`, `UiaHostProviderFromHwnd` at `:539`.
The `IRawElementProvider*` and `I*Provider` interfaces are in
`uiautomationcore.h`, with `IRawElementProviderSimple` at `:634`,
`ITextProvider` at `:5338`, `ITextRangeProvider` at `:5760` and
`struct UiaRect` at `:605`. A `translate-c` binding therefore needs four UI
Automation headers, not two. The import libraries for the free functions are
at `lib/libc/mingw/lib-common/uiautomationcore.def` and
`lib/libc/mingw/lib32/uiautomationcore.def`, and `lib-common/oleaut32.def`
covers `SafeArrayCreateVector` and `SafeArrayPutElement`.
