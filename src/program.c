#include "program.h"

#include <stdlib.h>

void compiled_program_init(CompiledProgram *prog) {
    prog->functions    = NULL;
    prog->count        = 0;
    prog->structs      = NULL;
    prog->struct_count = 0;
    prog->main_index   = -1;
    prog->result_enum_id = -1;
    prog->err_tag        = -1;
    prog->option_enum_id = -1;
    prog->none_tag       = -1;
    prog->variants       = NULL;
    prog->variant_count  = 0;
}





void compiled_program_free(CompiledProgram *prog) {
    for (int i = 0; i < prog->count; i++) {
        free(prog->functions[i].name);
        free(prog->functions[i].source_file);   // OFI-111a
        chunk_free(&prog->functions[i].chunk);
    }
    free(prog->functions);
    for (int i = 0; i < prog->struct_count; i++) {
        free(prog->structs[i].name);
        free(prog->structs[i].offset);        // per-field layout, sized to field_count (field dimension)
        free(prog->structs[i].kind);
        free(prog->structs[i].field_struct);
        if (prog->structs[i].field_names != NULL) {   // OFI-111b
            for (int f = 0; f < prog->structs[i].field_count; f++) {
                free(prog->structs[i].field_names[f]);
            }
            free(prog->structs[i].field_names);
        }
    }
    free(prog->structs);
    for (int i = 0; i < prog->variant_count; i++) {   // OFI-111b
        free(prog->variants[i].name);
    }
    free(prog->variants);
    compiled_program_init(prog);
}
