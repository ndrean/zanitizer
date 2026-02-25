/**
 * CSS Shim - C wrapper for Lexbor CSS struct access
 *
 * This provides safe accessors to Lexbor's internal CSS structures,
 * avoiding the need to mirror struct layouts in Zig.
 */

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
