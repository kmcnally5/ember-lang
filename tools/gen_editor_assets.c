// gen_editor_assets — emit editors/vscode/syntaxes/ember.tmLanguage.json from the single
// source of truth (include/vocab.def). A build-time-only developer tool, NOT part of emberc:
// emberc is what users and editors run; tools/ is what we run to maintain checked-in artifacts
// (OFI-033). The structural grammar rules (strings, numbers, operators, the fn-name capture)
// are authored here as literals; only the keyword / primitive / builtin alternations come from
// the table — so adding a word to vocab.def reflows the grammar with no hand-editing.
//
// TextMate grammars are strict JSON and cannot carry comment fences, so the whole file is
// generated and the Makefile guards it with a regenerate-and-diff check (`make check-editor-sync`).
//
// Writes the grammar to stdout. No dependencies beyond libc.

#include <stdio.h>
#include <string.h>

// The vocabulary, pulled in three times so each array sees only its own macro.
static const struct { const char *word; const char *cat; } KW[] = {
    #define EMBER_KEYWORD(tok, word, cat, gloss) { word, cat },
    #include "vocab.def"
};

static const char *PRIM[] = {
    #define EMBER_PRIM(name, doc) name,
    #include "vocab.def"
};

static const char *BUILTIN[] = {
    #define EMBER_BUILTIN(name, sig, doc) name,
    #include "vocab.def"
};


// join_kw fills `out` with the `|`-separated words whose grammar category is `cat`.
static void join_kw(char *out, const char *cat) {
    out[0] = '\0';
    int first = 1;
    for (size_t i = 0; i < sizeof KW / sizeof KW[0]; i++) {
        if (strcmp(KW[i].cat, cat) != 0) {
            continue;
        }
        if (!first) {
            strcat(out, "|");
        }
        strcat(out, KW[i].word);
        first = 0;
    }
}


// join_arr fills `out` with the `|`-separated entries of a plain name array.
static void join_arr(char *out, const char **a, size_t n) {
    out[0] = '\0';
    for (size_t i = 0; i < n; i++) {
        if (i != 0) {
            strcat(out, "|");
        }
        strcat(out, a[i]);
    }
}


#define L(s) fputs(s "\n", out)


int main(void) {
    FILE *out = stdout;

    char contract[256], control[256], decl[256], conc[128], other[256];
    char prim[512], boolc[64], builtin[1024];
    join_kw(contract, "contract");
    join_kw(control,  "control");
    join_kw(decl,     "declaration");
    join_kw(conc,     "concurrency");
    join_kw(other,    "other");
    join_kw(boolc,    "bool");
    join_arr(prim,    PRIM,    sizeof PRIM / sizeof PRIM[0]);
    join_arr(builtin, BUILTIN, sizeof BUILTIN / sizeof BUILTIN[0]);

    L("{");
    L("  \"$schema\": \"https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json\",");
    L("  \"name\": \"Ember\",");
    L("  \"scopeName\": \"source.ember\",");
    L("  \"fileTypes\": [\"em\"],");
    L("  \"patterns\": [");
    L("    { \"include\": \"#comments\" },");
    L("    { \"include\": \"#strings\" },");
    L("    { \"include\": \"#numbers\" },");
    L("    { \"include\": \"#contracts\" },");
    L("    { \"include\": \"#keywords\" },");
    L("    { \"include\": \"#types\" },");
    L("    { \"include\": \"#constants\" },");
    L("    { \"include\": \"#functions\" },");
    L("    { \"include\": \"#calls\" },");
    L("    { \"include\": \"#operators\" },");
    L("    { \"include\": \"#punctuation\" }");
    L("  ],");
    L("  \"repository\": {");
    L("    \"comments\": {");
    L("      \"patterns\": [");
    L("        {");
    L("          \"name\": \"comment.line.double-slash.ember\",");
    L("          \"begin\": \"//\",");
    L("          \"end\": \"$\"");
    L("        }");
    L("      ]");
    L("    },");
    L("    \"strings\": {");
    L("      \"name\": \"string.quoted.double.ember\",");
    L("      \"begin\": \"\\\"\",");
    L("      \"end\": \"\\\"\",");
    L("      \"patterns\": [");
    L("        {");
    L("          \"name\": \"constant.character.escape.ember\",");
    L("          \"match\": \"\\\\\\\\([\\\"\\\\\\\\{}nrt0]|.)\"");
    L("        },");
    L("        {");
    L("          \"name\": \"meta.embedded.interpolation.ember\",");
    L("          \"begin\": \"(?<!\\\\\\\\)\\\\{\",");
    L("          \"end\": \"\\\\}\",");
    L("          \"beginCaptures\": { \"0\": { \"name\": \"punctuation.section.interpolation.begin.ember\" } },");
    L("          \"endCaptures\": { \"0\": { \"name\": \"punctuation.section.interpolation.end.ember\" } },");
    L("          \"patterns\": [");
    L("            { \"include\": \"#strings\" },");
    L("            { \"include\": \"#numbers\" },");
    L("            { \"include\": \"#keywords\" },");
    L("            { \"include\": \"#types\" },");
    L("            { \"include\": \"#constants\" },");
    L("            { \"include\": \"#calls\" },");
    L("            { \"include\": \"#operators\" },");
    L("            { \"include\": \"#punctuation\" }");
    L("          ]");
    L("        }");
    L("      ]");
    L("    },");
    L("    \"numbers\": {");
    L("      \"patterns\": [");
    L("        {");
    L("          \"name\": \"constant.numeric.float.ember\",");
    L("          \"match\": \"\\\\b[0-9][0-9_]*\\\\.[0-9][0-9_]*\\\\b\"");
    L("        },");
    L("        {");
    L("          \"name\": \"constant.numeric.integer.ember\",");
    L("          \"match\": \"\\\\b[0-9][0-9_]*\\\\b\"");
    L("        }");
    L("      ]");
    L("    },");
    L("    \"contracts\": {");
    L("      \"name\": \"keyword.control.contract.ember\",");
    fprintf(out, "      \"match\": \"\\\\b(%s)\\\\b\"\n", contract);
    L("    },");
    L("    \"keywords\": {");
    L("      \"patterns\": [");
    L("        {");
    L("          \"name\": \"keyword.control.ember\",");
    fprintf(out, "          \"match\": \"\\\\b(%s)\\\\b\"\n", control);
    L("        },");
    L("        {");
    L("          \"name\": \"keyword.declaration.ember\",");
    fprintf(out, "          \"match\": \"\\\\b(%s)\\\\b\"\n", decl);
    L("        },");
    L("        {");
    L("          \"name\": \"keyword.concurrency.ember\",");
    fprintf(out, "          \"match\": \"\\\\b(%s)\\\\b\"\n", conc);
    L("        },");
    L("        {");
    L("          \"name\": \"keyword.other.ember\",");
    fprintf(out, "          \"match\": \"\\\\b(%s)\\\\b\"\n", other);
    L("        }");
    L("      ]");
    L("    },");
    L("    \"types\": {");
    L("      \"patterns\": [");
    L("        {");
    L("          \"name\": \"support.type.primitive.ember\",");
    fprintf(out, "          \"match\": \"\\\\b(%s)\\\\b\"\n", prim);
    L("        },");
    L("        {");
    L("          \"name\": \"entity.name.type.ember\",");
    L("          \"match\": \"\\\\b[A-Z][A-Za-z0-9_]*\\\\b\"");
    L("        }");
    L("      ]");
    L("    },");
    L("    \"constants\": {");
    L("      \"patterns\": [");
    L("        {");
    L("          \"name\": \"constant.language.boolean.ember\",");
    fprintf(out, "          \"match\": \"\\\\b(%s)\\\\b\"\n", boolc);
    L("        },");
    L("        {");
    L("          \"name\": \"variable.language.ember\",");
    L("          \"match\": \"\\\\b(self|result)\\\\b\"");
    L("        }");
    L("      ]");
    L("    },");
    L("    \"functions\": {");
    L("      \"name\": \"meta.function.ember\",");
    L("      \"match\": \"\\\\b(fn)\\\\s+([A-Za-z_][A-Za-z0-9_]*)\",");
    L("      \"captures\": {");
    L("        \"1\": { \"name\": \"keyword.declaration.ember\" },");
    L("        \"2\": { \"name\": \"entity.name.function.ember\" }");
    L("      }");
    L("    },");
    L("    \"calls\": {");
    L("      \"patterns\": [");
    L("        {");
    L("          \"name\": \"support.function.builtin.ember\",");
    fprintf(out, "          \"match\": \"\\\\b(%s)\\\\b(?=\\\\s*\\\\()\"\n", builtin);
    L("        },");
    L("        {");
    L("          \"match\": \"\\\\b([A-Za-z_][A-Za-z0-9_]*)\\\\b(?=\\\\s*\\\\()\",");
    L("          \"captures\": { \"1\": { \"name\": \"entity.name.function.call.ember\" } }");
    L("        }");
    L("      ]");
    L("    },");
    L("    \"operators\": {");
    L("      \"name\": \"keyword.operator.ember\",");
    L("      \"match\": \"(->|==|!=|<=|>=|&&|\\\\|\\\\||\\\\.\\\\.|[-+*/%<>=!|?])\"");
    L("    },");
    L("    \"punctuation\": {");
    L("      \"patterns\": [");
    L("        { \"name\": \"punctuation.separator.ember\", \"match\": \"[,:]\" },");
    L("        { \"name\": \"punctuation.accessor.ember\", \"match\": \"\\\\.\" }");
    L("      ]");
    L("    }");
    L("  }");
    L("}");

    return 0;
}
