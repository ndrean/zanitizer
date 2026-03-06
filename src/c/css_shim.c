/**
 * CSS Shim - C wrapper for Lexbor CSS struct access
 *
 * This provides safe accessors to Lexbor's internal CSS structures,
 * avoiding the need to mirror struct layouts in Zig.
 */

// Enable POSIX.1-2008 extensions (sigaction, siginfo_t, sigjmp_buf, etc.).
// Must be defined before ANY system header because glibc uses it as a gate.
// macOS exposes these unconditionally; Linux/glibc requires this define.
#ifndef __wasm__
#  define _POSIX_C_SOURCE 200809L
#endif

// SIGSEGV crash protection — must come before any Lexbor headers to avoid
// macro conflicts with signal.h on some platforms.
#include <stdint.h>

/* Callback type used by zexp_crash_protect_run(). */
typedef void (*ZexpProtectedFn)(void *ctx);

#ifndef __wasm__

#include <setjmp.h>
#include <signal.h>

/* Thread-local crash-recovery state.
 * When g_tl_armed != 0, a SIGSEGV in this thread is caught and execution
 * resumes at the sigsetjmp() call inside zexp_crash_protect_run(), which
 * returns 1 to its Zig caller.  Otherwise the old handler is chained.
 */
static _Thread_local sigjmp_buf  g_tl_recovery_buf;
static _Thread_local volatile sig_atomic_t g_tl_armed = 0;

static struct sigaction g_old_segv_sa;
static volatile sig_atomic_t g_handler_installed = 0;

static void segv_recovery_handler(int sig, siginfo_t *info, void *ucontext) {
    if (g_tl_armed) {
        g_tl_armed = 0;
        siglongjmp(g_tl_recovery_buf, 1);
    }
    /* Not armed — chain to previous handler so unprotected crashes still
     * produce the expected behaviour (core dump / debugger attach). */
    if (g_old_segv_sa.sa_flags & SA_SIGINFO) {
        g_old_segv_sa.sa_sigaction(sig, info, ucontext);
    } else if (g_old_segv_sa.sa_handler == SIG_DFL) {
        /* Restore default and re-raise so the OS generates a core. */
        signal(SIGSEGV, SIG_DFL);
        raise(SIGSEGV);
    } else if (g_old_segv_sa.sa_handler != SIG_IGN) {
        g_old_segv_sa.sa_handler(sig);
    }
}

/* Install the SIGSEGV recovery handler.  Safe to call multiple times. */
void zexp_crash_protect_install(void) {
    if (g_handler_installed) return;
    struct sigaction sa;
    sa.sa_sigaction = segv_recovery_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO;
    if (sigaction(SIGSEGV, &sa, &g_old_segv_sa) == 0) {
        g_handler_installed = 1;
    }
}

/* Run fn(user_ctx) with SIGSEGV protection.
 * Returns 0 on normal completion, 1 if a SIGSEGV was caught.
 */
int zexp_crash_protect_run(ZexpProtectedFn fn, void *user_ctx) {
    g_tl_armed = 1;
    if (sigsetjmp(g_tl_recovery_buf, 1) != 0) {
        g_tl_armed = 0;
        return 1;
    }
    fn(user_ctx);
    g_tl_armed = 0;
    return 0;
}

#else /* __wasm__ — no signals; crash protection is a no-op */

void zexp_crash_protect_install(void) {}
int  zexp_crash_protect_run(ZexpProtectedFn fn, void *user_ctx) {
    fn(user_ctx);
    return 0;
}

#endif /* __wasm__ */

#include <lexbor/css/css.h>
#include <lexbor/css/stylesheet.h>
#include <lexbor/css/rule.h>
#include <lexbor/css/declaration.h>
#include <lexbor/css/selectors/selectors.h>
#include <lexbor/style/dom/interfaces/document.h>
#include <lexbor/style/html/interfaces/document.h>
#include <lexbor/html/interfaces/document.h>
#include <lexbor/html/interfaces/element.h>
#include <lexbor/html/parser.h>

// ============================================================================
// Stylesheet Access
// ============================================================================

lxb_css_rule_t* zexp_css_stylesheet_get_root(lxb_css_stylesheet_t *sst) {
    return sst ? sst->root : NULL;
}

// ============================================================================
// Rule Access
// ============================================================================

lxb_css_rule_type_t zexp_css_rule_get_type(lxb_css_rule_t *rule) {
    return rule ? rule->type : LXB_CSS_RULE_UNDEF;
}

lxb_css_rule_t* zexp_css_rule_get_next(lxb_css_rule_t *rule) {
    return rule ? rule->next : NULL;
}

lxb_css_rule_t* zexp_css_rule_get_prev(lxb_css_rule_t *rule) {
    return rule ? rule->prev : NULL;
}

// ============================================================================
// Style Rule Access (selector + declarations)
// ============================================================================

lxb_css_selector_list_t* zexp_css_rule_style_get_selector(lxb_css_rule_t *rule) {
    if (rule == NULL || rule->type != LXB_CSS_RULE_STYLE) {
        return NULL;
    }
    lxb_css_rule_style_t *style = lxb_css_rule_style(rule);
    return style ? style->selector : NULL;
}

lxb_css_rule_declaration_list_t* zexp_css_rule_style_get_declarations(lxb_css_rule_t *rule) {
    if (rule == NULL || rule->type != LXB_CSS_RULE_STYLE) {
        return NULL;
    }
    lxb_css_rule_style_t *style = lxb_css_rule_style(rule);
    return style ? style->declarations : NULL;
}

// ============================================================================
// Declaration List Access
// ============================================================================

lxb_css_rule_t* zexp_css_decl_list_get_first(lxb_css_rule_declaration_list_t *list) {
    return list ? list->first : NULL;
}

size_t zexp_css_decl_list_get_count(lxb_css_rule_declaration_list_t *list) {
    return list ? list->count : 0;
}

// ============================================================================
// Declaration Access
// ============================================================================

// Get the property type ID (0 = undef, 1 = custom, 2+ = known properties)
uintptr_t zexp_css_declaration_get_type_id(lxb_css_rule_t *rule) {
    if (rule == NULL || rule->type != LXB_CSS_RULE_DECLARATION) {
        return 0;
    }
    lxb_css_rule_declaration_t *decl = (lxb_css_rule_declaration_t*)rule;
    return decl->type;
}

bool zexp_css_declaration_is_important(lxb_css_rule_t *rule) {
    if (rule == NULL || rule->type != LXB_CSS_RULE_DECLARATION) {
        return false;
    }
    lxb_css_rule_declaration_t *decl = (lxb_css_rule_declaration_t*)rule;
    return decl->important;
}

// ============================================================================
// Rule List Access (for @media blocks, etc.)
// ============================================================================

lxb_css_rule_t* zexp_css_rule_list_get_first(lxb_css_rule_t *rule) {
    if (rule == NULL || rule->type != LXB_CSS_RULE_LIST) {
        return NULL;
    }
    lxb_css_rule_list_t *list = lxb_css_rule_list(rule);
    return list ? list->first : NULL;
}

// ============================================================================
// At-Rule Access (@media, @import, etc.)
// ============================================================================

lxb_css_at_rule_type_t zexp_css_at_rule_get_type(lxb_css_rule_t *rule) {
    if (rule == NULL || rule->type != LXB_CSS_RULE_AT_RULE) {
        return LXB_CSS_AT_RULE__UNDEF;
    }
    lxb_css_rule_at_t *at = (lxb_css_rule_at_t*)rule;
    return at->type;
}

// Get the prelude position offsets for @media rules etc.
// NOTE: The at-rule struct uses position offsets (name_begin, prelude_begin, prelude_end)
// rather than direct string pointers. To get the actual prelude text, use
// lxb_css_rule_at_serialize() or the original CSS source with these offsets.
// This function returns the prelude_begin and prelude_end offsets.
void zexp_css_at_rule_get_prelude_offsets(lxb_css_rule_t *rule,
                                          size_t *prelude_begin,
                                          size_t *prelude_end) {
    if (rule == NULL || rule->type != LXB_CSS_RULE_AT_RULE) {
        if (prelude_begin) *prelude_begin = 0;
        if (prelude_end) *prelude_end = 0;
        return;
    }
    lxb_css_rule_at_t *at = (lxb_css_rule_at_t*)rule;
    if (prelude_begin) *prelude_begin = at->prelude_begin;
    if (prelude_end) *prelude_end = at->prelude_end;
}

// ============================================================================
// Document stylesheet cleanup
// ============================================================================

// Null-safe wrapper around lxb_html_document_stylesheet_destroy_all().
// The lexbor function uses lexbor_array_pop() and correctly skips stylesheets
// that share the CSS engine memory pool (css->memory != sst->memory), avoiding
// the double-free that a naive always-destroy loop would cause.
// Call this BEFORE lxb_html_document_css_destroy() to avoid leaks.
void zexp_destroy_document_stylesheets(lxb_html_document_t *document)
{
    if (document == NULL) return;
    lxb_dom_document_t *dom = lxb_dom_interface_document(document);
    if (dom == NULL || dom->css == NULL) return;
    lxb_html_document_stylesheet_destroy_all(document, true);
}

// ============================================================================
// Null-safe element style attachment
// ============================================================================

// lxb_dom_document_element_styles_attach() segfaults (at offset 0x28) when
// doc->css is NULL.  This safe variant skips the call gracefully, so scripts
// that manipulate the DOM without first calling initDocumentCSS() don't crash.
lxb_status_t zexp_element_styles_attach_safe(lxb_html_element_t *element)
{
    if (element == NULL) return LXB_STATUS_OK;
    lxb_dom_document_t *doc = lxb_dom_interface_node(element)->owner_document;
    if (doc == NULL || doc->css == NULL) return LXB_STATUS_OK;
    return lxb_dom_document_element_styles_attach(lxb_dom_interface_element(element));
}

// ============================================================================
// Scripting flag
// ============================================================================

// Enable/disable the scripting flag for the document's current parse.
// Must be called AFTER lxb_html_document_parse_chunk_begin() (which lazily
// creates the parser via lxb_html_document_parser_prepare), and BEFORE any
// lxb_html_document_parse_chunk() calls.
//
// Two flags must be set:
//   dom_document.scripting — checked by insertion mode handlers (e.g. noscript)
//   parser->tree->scripting — used by the tokenizer for raw-text element state
//
// When scripting=true, the parser treats <noscript> content as raw text
// (hidden from DOM), matching real browser behaviour for script-enabled pages.
void zexp_document_set_scripting(lxb_html_document_t *doc, bool scripting)
{
    if (doc == NULL) return;
    lxb_dom_document_t *d = lxb_dom_interface_document(doc);
    // Checked by in_body_noscript insertion mode handler:
    d->scripting = scripting;
    // Checked by tokenizer (lxb_html_tokenizer_set_state_by_tag, etc.):
    lxb_html_parser_t *parser = (lxb_html_parser_t *)d->parser;
    if (parser != NULL) {
        lxb_html_parser_scripting_set_noi(parser, scripting);
    }
}
